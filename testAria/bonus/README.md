# Bonus — K3d + ArgoCD + Gitea (Local GitOps)

This bonus extends Part 3 by replacing the public GitHub repository with a **local Gitea instance** running inside the cluster. Everything works the same as Part 3, but the entire GitOps flow is self-contained — no internet required after the initial setup.

---

## What is Gitea?

Gitea is a lightweight, self-hosted Git service. It provides the same core features as GitHub (repositories, branches, web UI, REST API) but runs entirely on your own machine or cluster. It is written in Go, uses minimal resources, and is ideal for local development environments.

In this bonus, Gitea replaces GitHub as the source of truth that ArgoCD watches.

---

## How it differs from Part 3

| | Part 3 | Bonus |
|---|---|---|
| Git source | GitHub (public, internet) | Gitea (local, inside cluster) |
| ArgoCD watches | `github.com/kchaouki/testArgo` | `gitea.gitea.svc.cluster.local:3000/gitea/testArgo` |
| Extra namespace | — | `gitea` |
| Extra port | — | `3000` (Gitea UI) |
| Repo secret | not needed (public) | `repo-secret.yml` (ArgoCD auth to Gitea) |

---

## Architecture

```
You (browser)
      │
      ├── http://gitea.localhost:3000   → Gitea UI  (push/edit manifests)
      ├── http://argocd.localhost:9090  → ArgoCD UI (monitor sync)
      └── http://localhost:8080         → The deployed app (dev namespace)

Inside the cluster:
  ArgoCD polls Gitea (internal URL) every 5 min
        ↓ detects change in confs/dev/
  ArgoCD syncs → updates the app in the dev namespace
        ↓
  Kubernetes pulls kchaouki/testapp:v1 (or v2) from DockerHub
```

---

## Namespaces

| Namespace | Purpose |
|---|---|
| `gitea` | Runs the local Gitea instance |
| `argocd` | Runs ArgoCD |
| `dev` | Runs the deployed application |

---

## Project Structure

```
bonus/
├── scripts/
│   ├── setup.sh      # full automated install (8 steps)
│   └── cleanup.sh    # full teardown
└── confs/
    ├── gitea/
    │   ├── pvc.yml         # persistent volume for Gitea data
    │   ├── deployment.yml  # Gitea pod (gitea/gitea:latest)
    │   ├── service.yml     # ClusterIP on port 3000
    │   └── ingress.yml     # routes gitea.localhost:3000 → Gitea
    ├── argocd/
    │   ├── repo-secret.yml  # ArgoCD credentials for local Gitea
    │   ├── application.yml  # ArgoCD Application (watches Gitea)
    │   ├── ingress.yml      # routes argocd.localhost:9090 → ArgoCD UI
    │   └── argocd-cm.yml    # sets poll interval to 5 min
    └── dev/
        ├── deployment.yml   # kchaouki/testapp:v1, namespace: dev
        ├── service.yml      # ClusterIP on port 80
        └── ingress.yml      # routes localhost:8080 → app
```

---

## Port Mapping

| Host | Container port | Routed to |
|---|---|---|
| `localhost:8080` | 80 (Traefik) | App in `dev` namespace |
| `localhost:8443` | 443 (Traefik) | HTTPS load balancer |
| `argocd.localhost:9090` | 80 (Traefik) | ArgoCD server |
| `gitea.localhost:3000` | 80 (Traefik) | Gitea HTTP |

All traffic goes through Traefik (k3d's built-in ingress controller), which routes by hostname.

---

## How to Run

### Install everything
```bash
cd bonus/scripts
./setup.sh
```

The script will automatically:
1. Install `kubectl`, `k3d`, `argocd` CLI
2. Create the K3d cluster with all port mappings
3. Create namespaces: `argocd`, `dev`, `gitea`
4. Deploy Gitea and wait for it to be ready
5. Create the Gitea admin user and repository via the Gitea API
6. Push the app manifests (`confs/dev/`) to local Gitea
7. Install ArgoCD and configure it to use local Gitea as the repo source
8. Register the ArgoCD Application

At the end it prints all credentials and URLs.

### Tear everything down
```bash
./cleanup.sh
```

---

## Access

| Service | URL | Credentials |
|---|---|---|
| App | http://localhost:8080 | — |
| ArgoCD UI | http://argocd.localhost:9090 | `admin` / printed by setup.sh |
| Gitea UI | http://gitea.localhost:3000 | `gitea` / `gitea123` |

> Make sure `/etc/hosts` has these entries (setup.sh adds them automatically):
> ```
> 127.0.0.1 argocd.localhost
> 127.0.0.1 gitea.localhost
> ```

---

## GitOps Demo — Switching v1 to v2

The key requirement: change the app version through the Git source and watch ArgoCD apply it automatically.

**Option A — via Gitea web UI:**
1. Open http://gitea.localhost:3000
2. Navigate to `testArgo` → `confs/dev/deployment.yml`
3. Click the pencil icon to edit
4. Change `kchaouki/testapp:v1` → `kchaouki/testapp:v2`
5. Commit the change

**Option B — via git CLI:**
```bash
# clone from local Gitea
git clone http://gitea:gitea123@gitea.localhost:3000/gitea/testArgo.git
cd testArgo

# update the image tag
sed -i '' 's/testapp:v1/testapp:v2/' confs/dev/deployment.yml
git add confs/dev/deployment.yml
git commit -m "upgrade app to v2"
git push
```

ArgoCD detects the change within 5 minutes and updates the pod in the `dev` namespace. You can force an immediate sync with:
```bash
argocd app sync myapp
```

Verify the running version:
```bash
curl http://localhost:8080
# {"status":"ok", "message": "v2"}
```

---

## Application Versions

| Tag | Response |
|---|---|
| `kchaouki/testapp:v1` | `{"status":"ok", "message": "v1"}` |
| `kchaouki/testapp:v2` | `{"status":"ok", "message": "v2"}` |

Both images are multi-platform (`linux/amd64` + `linux/arm64`) and hosted on DockerHub.
