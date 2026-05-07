# Bonus: Adding GitLab — Full Explanation

---

## What the subject ACTUALLY asks

Read this carefully — the subject says **GitLab**, not Gitea.

> "The following bonus task is intended to be useful: add **Gitlab** to the lab you completed in Part 3."

Requirements:
- Your **GitLab instance must run locally** (inside the cluster)
- Configure GitLab to work with your cluster
- Create a dedicated namespace named **`gitlab`**
- **Everything you did in Part 3 must work with your local GitLab** (ArgoCD watches local GitLab instead of GitHub)
- Use the **latest version of GitLab from the official website**
- You can use **Helm** (strongly recommended — it's the standard way to deploy GitLab on K8s)
- Put all files in the `bonus/` folder at the root of your repo

---

## Why GitLab is hard (the subject warns you)

> "Beware this bonus is complex."

GitLab is a heavy application. It is not like deploying a simple Python app. A full GitLab instance requires:
- A PostgreSQL database
- A Redis cache
- Object storage (or local disk)
- Several GitLab services (Workhorse, Gitaly, Sidekiq, Puma, etc.)

GitLab's official Helm chart handles all of this for you, which is why using **Helm is the right approach**.

---

## Concept 1: Helm

**Helm** is the package manager for Kubernetes. Think of it like `apt` or `brew` but for Kubernetes applications.

Instead of writing dozens of YAML files manually (like you did in Part 3), Helm lets you install complex applications with a single command, using pre-built **charts** (packages of templates + default values).

### Key terms
| Term | Meaning |
|---|---|
| **Chart** | A Helm package (like a .deb or .pkg) — a collection of templates |
| **Release** | An installed instance of a chart in your cluster |
| **Values** | Configuration you pass to customize a chart |
| **Repository** | A place that hosts Helm charts (like an apt mirror) |

### Basic Helm commands
```bash
# Install Helm
brew install helm

# Add a chart repository
helm repo add gitlab https://charts.gitlab.io/

# Update your local list of charts
helm repo update

# Search for a chart
helm search repo gitlab/gitlab

# Install a chart
helm install my-release gitlab/gitlab -f my-values.yml -n gitlab

# See what's installed
helm list -n gitlab

# Uninstall
helm uninstall my-release -n gitlab
```

---

## Concept 2: The Bonus Architecture

```
You (browser / git push)
      │
      ├── http://gitlab.localhost      → GitLab UI (push manifests here)
      ├── http://argocd.localhost:9090 → ArgoCD UI (monitor sync)
      └── http://localhost:8888        → The deployed app (dev namespace)

Inside the cluster:
  ArgoCD watches local GitLab (internal cluster URL)
        ↓ detects change in deployment.yml
  ArgoCD applies the change to dev namespace
        ↓
  Kubernetes pulls new image from DockerHub
        ↓
  App returns v2
```

### Namespaces

| Namespace | Purpose |
|---|---|
| `gitlab` | Runs the local GitLab instance |
| `argocd` | Runs ArgoCD (same as Part 3) |
| `dev` | Runs the deployed app (same as Part 3) |

---

## Concept 3: Deploying GitLab with Helm

### Step 1 — Install Helm
```bash
brew install helm
# or on Linux:
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
```

### Step 2 — Add GitLab Helm repository
```bash
helm repo add gitlab https://charts.gitlab.io/
helm repo update
```

### Step 3 — Create the gitlab namespace
```bash
kubectl create namespace gitlab
```

### Step 4 — Configure values for a minimal local install

GitLab's default Helm chart is designed for cloud (AWS, GCP). For a local K3d cluster, you need to disable cloud-specific things and reduce resource usage.

Create `bonus/confs/gitlab/values.yml`:
```yaml
# Use a local domain
global:
  hosts:
    domain: localhost
    https: false
    gitlab:
      name: gitlab.localhost
      https: false
    externalIP: 127.0.0.1

  # Disable cert-manager (we don't need TLS for local)
  ingress:
    configureCertmanager: false
    class: traefik       # use K3d's built-in Traefik
    tls:
      enabled: false

  # Use internal cluster PostgreSQL and Redis (no cloud)
  psql:
    password:
      secret: gitlab-postgresql-password
      key: postgresql-password

# Disable cloud/external dependencies not needed locally
certmanager-issuer:
  email: admin@gitlab.local

# Reduce replicas for local resource constraints
gitlab:
  webservice:
    minReplicas: 1
    maxReplicas: 1
  sidekiq:
    minReplicas: 1
    maxReplicas: 1
  gitlab-shell:
    minReplicas: 1
    maxReplicas: 1

# Disable things not needed locally
nginx-ingress:
  enabled: false       # use Traefik instead
prometheus:
  install: false       # disable monitoring to save resources
gitlab-runner:
  install: false       # don't need CI runner for this project
```

### Step 5 — Install GitLab
```bash
helm install gitlab gitlab/gitlab \
  -n gitlab \
  -f bonus/confs/gitlab/values.yml \
  --timeout 600s        # GitLab takes a long time to start (5-10 min)
```

Watch it come up:
```bash
kubectl get pods -n gitlab -w
```

### Step 6 — Get the initial root password
```bash
kubectl get secret gitlab-gitlab-initial-root-password \
  -n gitlab \
  -o jsonpath="{.data.password}" | base64 --decode
```
Username: `root`

---

## Concept 4: Exposing GitLab via Ingress (Traefik)

You need to access GitLab from your browser and from inside the cluster (for ArgoCD).

### Add to /etc/hosts
```
127.0.0.1 gitlab.localhost
```

### Ingress resource (if not handled by Helm values)
```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: gitlab
  namespace: gitlab
  annotations:
    ingress.kubernetes.io/ssl-redirect: "false"
spec:
  rules:
    - host: gitlab.localhost
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: gitlab-webservice-default
                port:
                  number: 8080
```

---

## Concept 5: Configuring ArgoCD to Watch Local GitLab

This is the core of the bonus. Instead of watching GitHub, ArgoCD now watches your local GitLab.

### Step 1 — Create a GitLab repository
1. Open http://gitlab.localhost
2. Login as `root`
3. Create a new project (e.g. `testArgo`) — set it to public or create credentials
4. Push your `confs/dev/` manifests to it

```bash
git clone http://root:<password>@gitlab.localhost/root/testArgo.git
cd testArgo
mkdir -p confs/dev
cp <your-dev-manifests>/* confs/dev/
git add .
git commit -m "add dev manifests"
git push
```

### Step 2 — Create an ArgoCD Repository Secret for GitLab auth
ArgoCD needs credentials to access local GitLab (even if the repo is public, the internal URL needs auth).

```yaml
# bonus/confs/argocd/repo-secret.yml
apiVersion: v1
kind: Secret
metadata:
  name: gitlab-repo-secret
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repository
stringData:
  type: git
  url: http://gitlab-webservice-default.gitlab.svc.cluster.local:8080/root/testArgo.git
  username: root
  password: <gitlab-root-password>
```

Apply it:
```bash
kubectl apply -f bonus/confs/argocd/repo-secret.yml
```

### Step 3 — Update the ArgoCD Application to point to GitLab

```yaml
# bonus/confs/argocd/application.yml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: myapp
  namespace: argocd
spec:
  project: default

  source:
    # Internal cluster URL to GitLab (ArgoCD runs inside the cluster)
    repoURL: http://gitlab-webservice-default.gitlab.svc.cluster.local:8080/root/testArgo.git
    targetRevision: HEAD
    path: confs/dev

  destination:
    server: https://kubernetes.default.svc
    namespace: dev

  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

Apply:
```bash
kubectl apply -f bonus/confs/argocd/application.yml
```

---

## Concept 6: Kubernetes Service DNS — Internal URLs

This is critical to understand. Inside a Kubernetes cluster, every Service gets a DNS name:

```
<service-name>.<namespace>.svc.cluster.local:<port>
```

So when ArgoCD (running inside the cluster in the `argocd` namespace) needs to reach GitLab (running in the `gitlab` namespace), it uses:
```
http://gitlab-webservice-default.gitlab.svc.cluster.local:8080
```

NOT `http://gitlab.localhost` — that external URL only works from outside the cluster.

This is why the repo-secret and Application manifest use the internal cluster DNS URL.

---

## Concept 7: PersistentVolumeClaim (PVC) — Storage

GitLab needs persistent storage to keep your repositories, databases, and uploaded files alive across pod restarts.

A **PersistentVolumeClaim** requests storage from the cluster. K3d/K3s automatically provisions local storage for PVCs.

The GitLab Helm chart creates PVCs automatically. You don't need to create them manually, but understand what they are:

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: gitlab-data
  namespace: gitlab
spec:
  accessModes:
    - ReadWriteOnce       # only one node can write at a time
  resources:
    requests:
      storage: 10Gi       # how much disk space to reserve
```

GitLab needs significantly more storage than simpler apps (at least 5-10Gi for a minimal install).

---

## Concept 8: The Bonus Setup Script

Your `bonus/scripts/setup.sh` must automate everything:

```
Step 1: Install kubectl, k3d, argocd CLI, helm
Step 2: Create K3d cluster (same port mappings as Part 3 + port for GitLab)
Step 3: Create namespaces: argocd, dev, gitlab
Step 4: Install GitLab via Helm (this takes 5-10 min)
Step 5: Wait for GitLab to be ready
Step 6: Create GitLab project + push dev manifests
Step 7: Install ArgoCD
Step 8: Configure ArgoCD: repo-secret pointing to local GitLab, ingress
Step 9: Apply ArgoCD Application (watches local GitLab)
Step 10: Print all credentials and URLs
```

---

## The Demo Flow for Bonus (evaluators will check)

1. Run `./bonus/scripts/setup.sh`
2. `kubectl get ns` → shows `argocd`, `dev`, `gitlab`
3. Open http://gitlab.localhost → GitLab UI running locally
4. Open http://argocd.localhost → ArgoCD watching local GitLab (not GitHub)
5. `curl http://localhost:8888/` → `{"status":"ok", "message": "v1"}`
6. Edit `deployment.yml` in the local GitLab UI → change `v1` → `v2` → commit
7. ArgoCD detects the change → syncs automatically
8. `curl http://localhost:8888/` → `{"status":"ok", "message": "v2"}`

---

## GitLab vs Gitea — Why the Subject Says GitLab

The subject explicitly requires **GitLab** (not Gitea). GitLab is the industry-standard self-hosted Git platform with full CI/CD, issue tracking, and registry features. It is much heavier than Gitea. If your current implementation uses Gitea, that does **not** satisfy the bonus requirement.

| | Gitea | GitLab |
|---|---|---|
| Weight | Very light (~256MB RAM) | Heavy (2-4GB RAM minimum) |
| Deploy | Simple Deployment YAML | Helm chart with 20+ services |
| Subject requirement | NOT required | REQUIRED for bonus |
| Features | Git + basic UI | Full DevOps platform |

---

## Resource Requirements Warning

GitLab is very resource-hungry. For a local K3d install you need at minimum:
- **4 CPU cores** available to the VM
- **6-8 GB RAM** available to the VM
- **20 GB disk** for GitLab data

If your VM is too small, GitLab pods will crash with OOMKilled errors.

---

## Checklist for Bonus

- [ ] `bonus/` folder exists at repo root
- [ ] Helm is installed and used to deploy GitLab
- [ ] GitLab runs locally in namespace `gitlab`
- [ ] GitLab UI accessible at http://gitlab.localhost
- [ ] GitLab project created with the dev manifests
- [ ] ArgoCD repo-secret created (credentials to access local GitLab)
- [ ] ArgoCD Application points to local GitLab (internal cluster URL)
- [ ] Namespace `argocd` and `dev` still work as in Part 3
- [ ] Full GitOps demo works: edit in GitLab → ArgoCD syncs → app updates
- [ ] Everything is in `bonus/scripts/setup.sh` (automated)
- [ ] Can explain: Helm, PVC, internal cluster DNS, GitLab vs GitHub for ArgoCD
