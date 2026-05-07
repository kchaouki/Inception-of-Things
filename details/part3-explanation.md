# Part 3: K3d and Argo CD — Full Explanation

---

## What the subject asks

- Install **K3d** on your virtual machine (no Vagrant in this part)
- Write a **script** that installs all necessary tools (Docker, K3d, kubectl, ArgoCD CLI)
- Create **2 namespaces** inside the cluster:
  - One namespace for **Argo CD** itself
  - One namespace named **`dev`** for your application
- The application in `dev` must be **automatically deployed by Argo CD** by watching a **public GitHub repository**
- The GitHub repo name must contain **the login of a team member**
- The app must have **two versions**: `v1` and `v2`
- You must demo changing the version in GitHub → ArgoCD detects it → app updates automatically
- You must show the ArgoCD UI with the synced app

---

## The Big Picture — What actually happens

```
You push a change to GitHub (e.g. change v1 → v2 in deployment.yaml)
          ↓
ArgoCD polls the repo every N seconds
          ↓
ArgoCD sees the difference between Git state and cluster state
          ↓
ArgoCD applies the new manifest automatically (kubectl apply internally)
          ↓
Kubernetes pulls the new image and replaces the pods
          ↓
curl http://localhost:8888/ now returns {"status":"ok", "message": "v2"}
```

This pattern is called **GitOps**: Git is the single source of truth for what runs in the cluster.

---

## Concept 1: K3s vs K3d — The Key Difference

You used **K3s** in Parts 1 and 2. In Part 3 you use **K3d**. Understanding the difference is important because evaluators will ask.

### K3s
- A **lightweight Kubernetes distribution** (stripped-down K8s)
- Runs directly on a **Linux machine** as a system process
- You installed it on a Vagrant VM with a shell script
- The VM itself acts as a Kubernetes node

### K3d
- A tool that runs **K3s inside Docker containers**
- Instead of needing a real VM or bare-metal machine, K3d spins up K3s nodes as Docker containers on your local machine
- The Docker containers simulate Kubernetes nodes (server + agents)
- Faster to create and destroy clusters (`k3d cluster create` / `k3d cluster delete`)
- Multiple clusters can coexist on one machine

**Why K3d in Part 3?**
Because Part 3 requires no Vagrant. You run everything on your existing VM using Docker + K3d.

### K3d cluster anatomy
```
Your VM
  └── Docker (running K3d)
        ├── container: k3d-server-0     (Kubernetes control plane)
        ├── container: k3d-agent-0      (worker node)
        ├── container: k3d-agent-1      (worker node)
        └── container: k3d-loadbalancer (maps host ports → cluster)
```

Creating a cluster with the required port mappings:
```bash
k3d cluster create argocd-cluster \
  --agents 2 \
  --port "8080:80@loadbalancer" \
  --port "8443:443@loadbalancer"
```
- `8080:80@loadbalancer` = port 8080 on your VM maps to port 80 inside the cluster's load balancer
- `--agents 2` = create 2 worker nodes in addition to the server node

---

## Concept 2: Namespaces

A **namespace** is a logical partition inside a Kubernetes cluster. Think of it as a folder that groups related resources (pods, services, deployments, etc.) and isolates them from other groups.

```
Cluster
├── namespace: argocd    ← ArgoCD runs here
├── namespace: dev       ← Your application runs here
└── namespace: default   ← Default namespace (not used in this part)
```

How to create namespaces:
```bash
kubectl create namespace argocd
kubectl create namespace dev
```

How to see all namespaces:
```bash
kubectl get ns
```

Expected output from the subject:
```
NAME      STATUS   AGE
argocd    Active   19h
dev       Active   19h
```

---

## Concept 3: The Application — Docker Image with Two Versions

The subject gives you two options:

### Option A: Use Wil's pre-made app (easier)
Available on Docker Hub: `wil42/playground`
- `wil42/playground:v1` → returns `{"status":"ok", "message": "v1"}`
- `wil42/playground:v2` → returns `{"status":"ok", "message": "v2"}`
- The app listens on **port 8888** (important: not 80)

### Option B: Make your own app
- Write any simple HTTP server (Python, Node.js, Go, etc.)
- Build a Docker image from it
- Push it to a **public Docker Hub repository**
- Tag it as `yourusername/yourapp:v1` and `yourusername/yourapp:v2`
- The two versions must have visible differences (e.g. different response text)

### What is Docker image tagging?
A **tag** is a label on a Docker image that identifies a specific version:
```
yourdockerhubuser/yourapp:v1   ← version 1
yourdockerhubuser/yourapp:v2   ← version 2
yourdockerhubuser/yourapp:latest ← always points to the newest
```

To build and push:
```bash
docker build -t yourusername/yourapp:v1 .
docker push yourusername/yourapp:v1

# Make code change, then:
docker build -t yourusername/yourapp:v2 .
docker push yourusername/yourapp:v2
```

---

## Concept 4: Kubernetes Manifests (YAML files)

Everything in Kubernetes is declared in YAML files called **manifests**. You describe what you want, Kubernetes makes it happen.

### Deployment
A **Deployment** tells Kubernetes: "run N copies of this container, keep them alive, restart if they crash."

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: wil-playground
  namespace: dev
spec:
  replicas: 1
  selector:
    matchLabels:
      app: wil-playground
  template:
    metadata:
      labels:
        app: wil-playground
    spec:
      containers:
        - name: wil-playground
          image: wil42/playground:v1   # ← this is what ArgoCD will update
          ports:
            - containerPort: 8888
```

Key fields:
- `replicas`: how many pod copies to run
- `image`: which Docker image to use (with tag = version)
- `containerPort`: the port the app listens on inside the container

### Service
A **Service** gives your pods a stable internal address so other things can reach them.

```yaml
apiVersion: v1
kind: Service
metadata:
  name: wil-playground
  namespace: dev
spec:
  selector:
    app: wil-playground   # matches pods with this label
  ports:
    - port: 8888
      targetPort: 8888
```

### Ingress
An **Ingress** exposes your service to traffic from outside the cluster (your browser / curl).

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: wil-playground
  namespace: dev
  annotations:
    ingress.kubernetes.io/ssl-redirect: "false"
spec:
  rules:
    - http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: wil-playground
                port:
                  number: 8888
```

With K3d and its built-in **Traefik** ingress controller, traffic flows like this:
```
curl http://localhost:8080
   → VM port 8080
   → K3d load balancer port 80
   → Traefik (ingress controller)
   → wil-playground Service
   → Pod running wil42/playground:v1
```

Note: if you use Wil's app (port 8888), make sure your K3d port mapping and service both handle 8888 correctly.

---

## Concept 5: ArgoCD

**ArgoCD** is a GitOps continuous delivery tool for Kubernetes. It watches a Git repo and keeps your cluster synchronized with what's in Git.

### How ArgoCD works
1. You install ArgoCD into the cluster (in the `argocd` namespace)
2. You create an **Application** resource that tells ArgoCD:
   - Which GitHub repo to watch
   - Which folder in that repo contains the manifests
   - Which namespace to deploy into
3. ArgoCD polls the repo every N seconds
4. When it detects a difference (Git ≠ cluster), it applies the change

### Installing ArgoCD into the cluster
```bash
kubectl apply -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
```

Wait for it to be ready:
```bash
kubectl rollout status deployment/argocd-server -n argocd --timeout=180s
```

### The ArgoCD Application manifest
This is the key resource. It registers your app with ArgoCD:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: myapp
  namespace: argocd        # always in the argocd namespace
spec:
  project: default

  source:
    repoURL: https://github.com/yourlogin/yourrepo.git
    targetRevision: HEAD   # always watch the latest commit on main
    path: confs/dev        # folder inside the repo containing deployment.yml etc.

  destination:
    server: https://kubernetes.default.svc  # the local cluster
    namespace: dev                          # deploy into the dev namespace

  syncPolicy:
    automated:
      prune: true      # delete resources removed from Git
      selfHeal: true   # revert manual cluster changes back to Git state
    syncOptions:
      - CreateNamespace=true  # create the dev namespace if it doesn't exist
```

Apply it:
```bash
kubectl apply -f application.yml
```

### Accessing the ArgoCD UI
By default ArgoCD runs with HTTPS and no ingress. To access it from a browser:

**Option 1 - Port forward (simplest):**
```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443
# then open https://localhost:8080
```

**Option 2 - Ingress (cleaner, what the project uses):**
First patch ArgoCD to run in insecure (HTTP) mode:
```bash
kubectl patch deployment argocd-server -n argocd \
  --type json \
  -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--insecure"}]'
```

Then apply an Ingress:
```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: argocd-server
  namespace: argocd
  annotations:
    ingress.kubernetes.io/ssl-redirect: "false"
spec:
  rules:
    - host: argocd.localhost
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: argocd-server
                port:
                  number: 80
```

Add to `/etc/hosts`:
```
127.0.0.1 argocd.localhost
```

### Getting the ArgoCD admin password
```bash
kubectl get secret argocd-initial-admin-secret \
  -n argocd \
  -o jsonpath="{.data.password}" | base64 --decode
```
Login: `admin` / (printed password)

---

## Concept 6: The GitHub Repository Structure

Your public GitHub repo must contain the Kubernetes manifests that ArgoCD will watch. Suggested structure:

```
yourlogin-testArgo/
└── confs/
    └── dev/
        ├── deployment.yml   ← ArgoCD watches this
        ├── service.yml
        └── ingress.yml
```

The ArgoCD Application's `path: confs/dev` points to this folder.

When you change `image: wil42/playground:v1` to `image: wil42/playground:v2` in `deployment.yml` and push, ArgoCD detects it within the poll interval and applies the update.

---

## Concept 7: The Install Script

The subject says: "you must write a script to install all the necessary packages and tools during your defense."

Your `p3/scripts/setup.sh` must:
1. Install `kubectl` (Kubernetes CLI)
2. Install `k3d`
3. Install `argocd` CLI (optional but useful)
4. Install `Docker` (or verify it's present)
5. Create the K3d cluster with port mappings
6. Create the `argocd` and `dev` namespaces
7. Install ArgoCD into the cluster
8. Apply the ArgoCD ingress
9. Apply the ArgoCD Application manifest (which points to your GitHub repo)
10. Print the ArgoCD admin password

---

## The Demo Flow (what evaluators will check)

1. Run `./setup.sh` — cluster comes up with ArgoCD + app in `dev`
2. `kubectl get ns` → shows `argocd` and `dev`
3. `kubectl get pods -n dev` → shows pod running `v1`
4. `curl http://localhost:8888/` → `{"status":"ok", "message": "v1"}`
5. Open ArgoCD UI → shows app is Synced + Healthy
6. Edit `deployment.yml` on GitHub: change `v1` → `v2`, commit + push
7. Wait (or force sync: `argocd app sync myapp`)
8. `kubectl get pods -n dev` → old pod terminating, new pod starting
9. `curl http://localhost:8888/` → `{"status":"ok", "message": "v2"}`
10. ArgoCD UI → shows the sync event and new state

---

## Checklist for Part 3

- [ ] Script installs Docker, K3d, kubectl automatically
- [ ] K3d cluster created with correct port mappings
- [ ] Namespace `argocd` exists
- [ ] Namespace `dev` exists
- [ ] ArgoCD is installed and running in `argocd` namespace
- [ ] ArgoCD UI is accessible (port-forward or ingress)
- [ ] Public GitHub repo exists with manifests in it
- [ ] ArgoCD Application manifest points to your GitHub repo
- [ ] App running in `dev` namespace with image `v1`
- [ ] Can demo: push v2 to GitHub → ArgoCD syncs → app shows v2
- [ ] Understand and can explain: K3s vs K3d, GitOps, ArgoCD Application, namespaces
