# Concepts Glossary — Everything You Need to Know

This file covers every concept you need to master for Part 3 and the Bonus, from scratch.

---

## Docker

A platform that packages applications into **containers** — isolated environments that contain the app + all its dependencies. Runs the same on any machine.

Key commands:
```bash
docker build -t user/app:v1 .      # build image from Dockerfile
docker push user/app:v1            # push to Docker Hub
docker pull user/app:v1            # pull from Docker Hub
docker run -p 8888:8888 user/app:v1  # run locally
docker images                      # list local images
docker ps                          # list running containers
```

A **Dockerfile** describes how to build an image:
```dockerfile
FROM python:3.11-slim
COPY app.py .
CMD ["python", "app.py"]
```

---

## Kubernetes (K8s)

An orchestration system that manages containers at scale. You describe the desired state in YAML files, Kubernetes makes it happen and keeps it that way.

### Core resources

**Pod** — the smallest deployable unit. One or more containers running together.

**Deployment** — manages pods. Ensures N replicas are always running. Handles rolling updates.

**Service** — gives pods a stable network identity (IP + DNS name) inside the cluster.

**Ingress** — routes external HTTP traffic into the cluster based on hostname/path rules.

**Namespace** — logical isolation. Groups resources. Like a folder inside the cluster.

**Secret** — stores sensitive data (passwords, tokens) as base64-encoded values.

**ConfigMap** — stores non-sensitive configuration data as key-value pairs.

**PersistentVolumeClaim (PVC)** — requests persistent disk storage for a pod.

### kubectl — the Kubernetes CLI

```bash
kubectl get pods -n dev                    # list pods in dev namespace
kubectl get pods -n dev -w                 # watch pods (live updates)
kubectl get ns                             # list namespaces
kubectl get all -n argocd                  # list all resources in argocd namespace
kubectl describe pod <name> -n dev         # detailed info + events (debugging)
kubectl logs <pod-name> -n dev             # read pod logs
kubectl apply -f file.yml                  # apply a manifest
kubectl delete -f file.yml                 # delete resources from a manifest
kubectl create namespace dev               # create a namespace
kubectl exec -it <pod> -n dev -- sh        # shell into a running pod
kubectl port-forward svc/argocd-server -n argocd 8080:443  # forward port
```

---

## K3s

A lightweight Kubernetes distribution made by Rancher. Same API as full K8s but smaller binary, fewer resources. Ships with **Traefik** as the default ingress controller.

Used in Parts 1 and 2 (installed on Vagrant VMs).

---

## K3d

A tool that runs K3s inside Docker containers on your local machine. Creates a fully functional K8s cluster in seconds using Docker containers as nodes.

```bash
# Create cluster with port mappings
k3d cluster create mycluster \
  --agents 2 \
  --port "8080:80@loadbalancer" \
  --port "8443:443@loadbalancer"

# Merge kubeconfig so kubectl works
k3d kubeconfig merge mycluster --kubeconfig-merge-default

# Switch context
kubectl config use-context k3d-mycluster

# List clusters
k3d cluster list

# Delete cluster
k3d cluster delete mycluster
```

Port mapping syntax: `hostPort:clusterPort@loadbalancer`
- `8080:80@loadbalancer` = laptop port 8080 → cluster load balancer port 80

---

## Traefik (Ingress Controller)

Built into K3s/K3d. Acts as a reverse proxy: receives HTTP requests and routes them to the right Service based on `Ingress` rules.

```
Browser → localhost:8080 → K3d load balancer → Traefik → Service → Pod
```

You don't configure Traefik directly — you write `Ingress` resources and Traefik reads them.

---

## ArgoCD

A GitOps CD (continuous delivery) tool. It watches a Git repository and automatically keeps the cluster state synchronized with what's in Git.

### Key ArgoCD concepts

**Application** — a CRD (Custom Resource Definition) that tells ArgoCD:
- Where the Git repo is (`repoURL`)
- Which branch/commit to watch (`targetRevision: HEAD`)
- Which folder in the repo has the manifests (`path`)
- Where to deploy it in the cluster (`destination.namespace`)

**Sync** — the act of making the cluster match Git (applying manifests)

**Automated sync** — ArgoCD syncs without you having to click a button

**prune: true** — if you delete a manifest from Git, ArgoCD deletes the resource from the cluster too

**selfHeal: true** — if someone manually changes the cluster (kubectl apply), ArgoCD reverts it to match Git

**timeout.reconciliation** — how often ArgoCD polls the repo (default 3 min, you can set 300s = 5 min)

### ArgoCD CLI

```bash
# Login
argocd login localhost:8080 --username admin --password <pass> --insecure

# List apps
argocd app list

# Force immediate sync
argocd app sync myapp

# Get app status
argocd app get myapp

# Watch sync progress
argocd app wait myapp
```

---

## GitOps

A practice where **Git is the single source of truth** for the desired state of your infrastructure. Instead of running `kubectl apply` manually, you push to Git and a tool (ArgoCD) applies it.

Benefits:
- Full audit trail (every change is a git commit)
- Easy rollback (git revert)
- No manual kubectl commands needed after initial setup
- Cluster always matches what's in Git

---

## Helm

The package manager for Kubernetes. Installs complex applications using pre-built **charts** (bundles of Kubernetes YAML templates).

```bash
# Install Helm
brew install helm

# Add a chart repository
helm repo add gitlab https://charts.gitlab.io/
helm repo update

# Install a release
helm install myrelease chart/name -n namespace -f values.yml

# List installed releases
helm list -n namespace

# Uninstall
helm uninstall myrelease -n namespace

# See what a chart will create (dry run, no install)
helm template myrelease chart/name -f values.yml
```

**Values file** (`values.yml`) — a YAML file with configuration to customize a chart's behavior. You override the chart's defaults.

---

## Namespaces (deep dive)

```bash
# Create
kubectl create namespace dev

# Idempotent create (won't fail if already exists)
kubectl create namespace dev --dry-run=client -o yaml | kubectl apply -f -

# List
kubectl get ns

# All resources in a namespace
kubectl get all -n dev

# Delete namespace (deletes everything inside it!)
kubectl delete namespace dev
```

Resources in different namespaces are isolated. A Service in `dev` is not reachable by name from `argocd` unless you use the full DNS name:
```
<service>.<namespace>.svc.cluster.local
```

---

## Internal Cluster DNS

Every Kubernetes Service gets an automatic DNS name inside the cluster:

```
<service-name>.<namespace>.svc.cluster.local:<port>
```

Examples:
- `argocd-server.argocd.svc.cluster.local:80`
- `gitlab-webservice-default.gitlab.svc.cluster.local:8080`
- `gitea.gitea.svc.cluster.local:3000`

This is how services in different namespaces talk to each other. External hostnames like `http://gitlab.localhost` only work from outside the cluster (your browser/curl). ArgoCD running inside the cluster must use internal DNS.

---

## Secrets in Kubernetes

Secrets store sensitive data. Values are base64-encoded (not encrypted by default).

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: my-secret
  namespace: argocd
stringData:            # use stringData — Kubernetes encodes it for you
  username: admin
  password: mysecretpassword
```

ArgoCD repository secrets need a special label so ArgoCD recognizes them:
```yaml
labels:
  argocd.argoproj.io/secret-type: repository
```

Read a secret value:
```bash
kubectl get secret my-secret -n argocd \
  -o jsonpath="{.data.password}" | base64 --decode
```

---

## PersistentVolumeClaim (PVC)

Requests persistent disk storage for a pod. Without a PVC, data is lost when a pod restarts.

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: myapp-data
  namespace: myapp-ns
spec:
  accessModes:
    - ReadWriteOnce     # one node can write at a time
  resources:
    requests:
      storage: 1Gi      # request 1 gigabyte
```

K3d/K3s automatically provisions local storage for PVCs using its built-in local path provisioner.

Attach a PVC to a pod in a Deployment:
```yaml
spec:
  volumes:
    - name: data-volume
      persistentVolumeClaim:
        claimName: myapp-data
  containers:
    - name: myapp
      volumeMounts:
        - name: data-volume
          mountPath: /data   # where inside the container the storage appears
```

---

## Docker Image Tagging

Tags identify specific versions of an image:

```bash
# Build with a specific tag
docker build -t yourusername/yourapp:v1 .
docker build -t yourusername/yourapp:v2 .

# Push both tags
docker push yourusername/yourapp:v1
docker push yourusername/yourapp:v2

# Run a specific version
docker run yourusername/yourapp:v1
docker run yourusername/yourapp:v2
```

In your Kubernetes Deployment, you reference a specific tag:
```yaml
image: wil42/playground:v1    # ← ArgoCD watches this line
```

Changing this tag in Git and pushing triggers ArgoCD to update the running pod.

---

## /etc/hosts

A local file that maps hostnames to IP addresses, bypassing DNS. Used to make `argocd.localhost` and `gitlab.localhost` work in your browser without a real DNS server.

```
127.0.0.1 argocd.localhost
127.0.0.1 gitlab.localhost
```

Add entries:
```bash
echo "127.0.0.1 argocd.localhost" | sudo tee -a /etc/hosts
echo "127.0.0.1 gitlab.localhost" | sudo tee -a /etc/hosts
```

---

## Debugging Commands (useful during evaluation)

```bash
# Is the cluster up?
kubectl get nodes

# Are all pods running?
kubectl get pods -A          # -A = all namespaces

# Why is a pod not starting?
kubectl describe pod <pod-name> -n <namespace>

# Read pod logs
kubectl logs <pod-name> -n <namespace>

# Follow logs live
kubectl logs -f <pod-name> -n <namespace>

# Is ArgoCD watching the right repo?
kubectl get secret -n argocd -l argocd.argoproj.io/secret-type=repository

# What applications does ArgoCD know about?
kubectl get applications -n argocd

# Force ArgoCD to sync now
argocd app sync myapp

# Check ArgoCD app status
argocd app get myapp

# See K3d cluster info
k3d cluster list
k3d cluster get argocd-cluster

# Check ingress rules
kubectl get ingress -A
```
