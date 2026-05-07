# ArgoCD GitOps Project

A complete local GitOps setup using K3d, Kubernetes, and ArgoCD. The goal is to have ArgoCD automatically watch a GitHub repository and deploy any changes to a local Kubernetes cluster — no manual `kubectl apply` needed after the initial setup.

---

## What is GitOps?

GitOps is a practice where your **Git repository is the single source of truth** for what should be running in your cluster. Instead of manually applying changes, you push to Git and a tool (ArgoCD in this case) detects the change and applies it automatically.

```
You push code to GitHub
        ↓
ArgoCD detects the change (polls every 5 min)
        ↓
ArgoCD applies the new manifests to the cluster
        ↓
Cluster matches Git exactly
```

---

## Tools Used

### Docker
Docker is a platform that packages applications into **containers** — lightweight, isolated environments that run the same way on any machine. In this project, Docker is used to:
- Build the app image from the `Dockerfile`
- Push the image to DockerHub so Kubernetes can pull it
- Run K3d (which uses Docker under the hood to simulate Kubernetes nodes)

### DockerHub
DockerHub is a public registry where Docker images are stored and shared. This project uses it to host the app image (`kchaouki/testapp:1.0`) so that the Kubernetes cluster can pull and run it.

### K3d
K3d is a tool that runs **K3s** (a lightweight Kubernetes distribution) inside Docker containers on your local machine. Instead of needing a real cloud cluster or a heavy VM-based setup like Minikube, K3d spins up a full Kubernetes cluster in seconds using Docker containers as nodes.

- **Server node** — the control plane (manages the cluster)
- **Agent nodes** — the worker nodes (run your pods)
- **Load balancer** — maps ports from your laptop to the cluster

In this project the cluster is named `argocd-cluster` and has 1 server + 2 agents.

### K3s
K3s is the lightweight Kubernetes distribution that K3d runs. It is a fully compliant Kubernetes but stripped of non-essential components to be fast and resource-efficient. It ships with **Traefik** as the default ingress controller.

### Kubernetes
Kubernetes (K8s) is an open-source system for automating deployment, scaling, and management of containerized applications. The key resources used in this project:

| Resource | Purpose |
|---|---|
| `Deployment` | Runs and manages the app pods (ensures 2 replicas are always up) |
| `Service` | Gives the pods a stable internal IP and DNS name inside the cluster |
| `Ingress` | Exposes the app and ArgoCD UI to your browser via the load balancer |
| `Namespace` | Logical separation — ArgoCD runs in the `argocd` namespace, the app in `default` |

### Traefik
Traefik is the **ingress controller** that comes built into K3s. It acts as a reverse proxy — it receives incoming HTTP requests and routes them to the correct service inside the cluster based on the hostname or path defined in `Ingress` resources.

- `http://localhost:8080` → routes to `myapp` service
- `http://argocd.localhost:9090` → routes to `argocd-server` service

### ArgoCD
ArgoCD is a **GitOps continuous delivery tool** for Kubernetes. It watches a Git repository and automatically syncs the cluster state to match what is defined in Git.

Key ArgoCD concepts used in this project:

| Concept | Meaning |
|---|---|
| `Application` | Tells ArgoCD which repo to watch, which folder, and where to deploy |
| `syncPolicy.automated` | ArgoCD syncs automatically without manual approval |
| `prune: true` | If a manifest is deleted from Git, ArgoCD deletes it from the cluster too |
| `selfHeal: true` | If someone manually changes the cluster, ArgoCD reverts it to match Git |
| `timeout.reconciliation` | How often ArgoCD polls the repo (set to 300s / 5 min in this project) |

---

## Project Structure

```
ArgoCd/
├── setup.sh               # One command to install and configure everything
├── cleanup.sh             # One command to tear everything down
├── install-k3d.sh         # Installs kubectl + k3d and creates the cluster
├── install-argocd.sh      # Installs ArgoCD into the cluster
├── apply-app.sh           # Registers the app with ArgoCD
│
├── k8s/                   # Kubernetes manifests (watched by ArgoCD)
│   ├── deployment.yml     # Deploys kchaouki/testapp:1.0 with 2 replicas
│   ├── service.yml        # ClusterIP service on port 80
│   └── ingress.yml        # Exposes the app at http://localhost:8080
│
├── argocd/
│   ├── application.yml    # ArgoCD Application — watches github.com/kchaouki/testArgo
│   ├── ingress.yml        # Exposes ArgoCD UI at http://argocd.localhost:9090
│   └── argocd-cm.yml      # ArgoCD config (sets poll interval to 5 min)
│
└── testApp/
    ├── DockerFile         # Builds the Python app image
    └── testApp.py         # Simple HTTP server that returns "Hello, I am App1"
```

---

## The App

A minimal Python HTTP server that responds to any GET request:

```python
# Returns: "Hello, I am App1"
HTTPServer(("0.0.0.0", 80), Handler).serve_forever()
```

Built as a multi-platform Docker image (supports both `amd64` and `arm64`):

```bash
docker buildx build --platform linux/amd64,linux/arm64 \
  -t kchaouki/testapp:1.0 --push -f DockerFile .
```

---

## Port Mapping

| Host (your browser) | Goes to | Purpose |
|---|---|---|
| `localhost:8080` | Traefik → myapp service | The deployed app |
| `localhost:8443` | Traefik (HTTPS) | HTTPS load balancer |
| `argocd.localhost:9090` | Traefik → argocd-server | ArgoCD UI |

---

## How to Run

### Full install (first time)
```bash
./setup.sh
```

This will:
1. Install `kubectl`, `k3d`, and `argocd` CLI via Homebrew
2. Create the K3d cluster with the correct port mappings
3. Install ArgoCD into the cluster
4. Apply the ArgoCD ingress
5. Register the app — ArgoCD starts watching the repo immediately

At the end it prints the ArgoCD admin password.

### Access

| URL | What |
|---|---|
| http://localhost:8080 | Your app |
| http://argocd.localhost:9090 | ArgoCD UI (user: `admin`) |

> Make sure `argocd.localhost` is in `/etc/hosts` → `127.0.0.1 argocd.localhost`

### Force an immediate sync
```bash
argocd app sync myapp
```

### Tear everything down
```bash
./cleanup.sh
```

---

## How Changes Flow (GitOps in action)

1. Edit `k8s/deployment.yml` (e.g. change the image tag or replica count)
2. `git push`
3. Within 5 minutes ArgoCD detects the change and applies it
4. The cluster updates automatically — no `kubectl apply` needed
