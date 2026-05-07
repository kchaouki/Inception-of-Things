# Inception of Things (IoT) — Kubernetes Project

A progressive Kubernetes learning project covering K3s cluster setup, Ingress routing, GitOps with ArgoCD, and a bonus Gitea integration. Built as part of the 42 school curriculum.

---

## Table of Contents

- [Overview](#overview)
- [Prerequisites](#prerequisites)
- [Project Structure](#project-structure)
- [Part 1 — K3s Cluster with Vagrant](#part-1--k3s-cluster-with-vagrant)
- [Part 2 — K3s Single Node with Ingress](#part-2--k3s-single-node-with-ingress)
- [Part 3 — K3d with ArgoCD (GitOps)](#part-3--k3d-with-argocd-gitops)
- [Bonus — ArgoCD + Gitea (Self-hosted Git)](#bonus--argocd--gitea-self-hosted-git)
- [Key Concepts](#key-concepts)
- [Useful Commands](#useful-commands)

---

## Overview

| Part   | Technology          | Description                                              |
|--------|---------------------|----------------------------------------------------------|
| Part 1 | K3s + Vagrant       | 2-node cluster: one controller, one worker agent         |
| Part 2 | K3s + Vagrant       | Single node running 3 apps with Ingress host routing     |
| Part 3 | K3d + ArgoCD        | GitOps: ArgoCD auto-deploys from a public GitHub repo    |
| Bonus  | K3d + ArgoCD + Gitea | Same GitOps pipeline with a self-hosted Gitea instance  |

---

## Prerequisites

| Tool        | Purpose                          | Install                                      |
|-------------|----------------------------------|----------------------------------------------|
| VirtualBox  | VM hypervisor (Parts 1 & 2)      | https://www.virtualbox.org/                  |
| Vagrant     | VM provisioner (Parts 1 & 2)     | https://www.vagrantup.com/                   |
| Docker      | Container runtime (Parts 3 & Bonus) | https://docs.docker.com/get-docker/       |
| kubectl     | Kubernetes CLI                   | https://kubernetes.io/docs/tasks/tools/      |
| k3d         | K3s-in-Docker (Parts 3 & Bonus)  | Auto-installed by setup scripts              |
| Helm        | Kubernetes package manager (Bonus)| https://helm.sh/docs/intro/install/         |

---

## Project Structure

```
K8s/
├── p1/
│   └── Vagrantfile              # 2-VM K3s cluster (controller + agent)
├── p2/
│   ├── Vagrantfile              # Single K3s VM
│   ├── confs/
│   │   ├── deployment-app1.yml  # App1 deployment + ClusterIP service (1 replica)
│   │   ├── deployment-app2.yml  # App2 deployment + ClusterIP service (3 replicas)
│   │   ├── deployment-app3.yml  # App3 deployment + ClusterIP service
│   │   └── ingress.yml          # Ingress: app1.com → app1, app2.com → app2, default → app3
│   └── scripts/
│       └── script.sh            # Installs K3s and applies all manifests
├── p3/
│   ├── confs/
│   │   ├── app-argo.yaml        # ArgoCD Application (watches GitHub repo)
│   │   ├── ingress-argocd.yaml  # Ingress for ArgoCD UI (HTTPS via Traefik)
│   │   └── ingress-dev.yaml     # Ingress for app in dev namespace
│   └── scripts/
│       └── setup.sh             # Creates k3d cluster, installs ArgoCD, applies configs
├── bonus/
│   ├── confs/
│   │   ├── app-argo.yaml        # ArgoCD Application (watches internal Gitea repo)
│   │   ├── ingress-argocd.yaml  # Ingress for ArgoCD UI
│   │   └── ingress-dev.yaml     # Ingress for app in dev namespace
│   └── scripts/
│       └── setup.sh             # Full setup: k3d + ArgoCD + Gitea via Helm
└── details/
    ├── concepts-glossary.md     # Full reference for K8s, K3s, K3d, ArgoCD, Helm
    ├── part3-explanation.md     # Deep-dive on Part 3 concepts and demo flow
    └── bonus-explanation.md     # Bonus part walkthrough
```

---

## Part 1 — K3s Cluster with Vagrant

Two Debian VMs on a private network. The server node runs K3s in controller mode; the worker node joins as an agent.

### Network

| VM          | Role       | IP               |
|-------------|------------|------------------|
| ael-aminS   | Controller | 192.168.56.110   |
| ael-aminSW  | Agent      | 192.168.56.111   |

### Setup

```bash
cd p1
vagrant up
```

Vagrant provisions both VMs automatically:
- **Controller**: installs K3s in server mode, binds to `192.168.56.110`
- **Agent**: waits for the controller API on port 6443, then joins the cluster

### Verify

```bash
vagrant ssh ael-aminS
kubectl get nodes
```

Expected output:
```
NAME          STATUS   ROLES                  AGE   VERSION
ael-aminS     Ready    control-plane,master   Xm    v1.x.x
ael-aminSW    Ready    <none>                 Xm    v1.x.x
```

---

## Part 2 — K3s Single Node with Ingress

One Debian VM running K3s with three applications deployed and an Ingress controller routing traffic by hostname.

### Network

| VM          | IP               |
|-------------|------------------|
| kchaoukiS   | 192.168.56.110   |

### Applications

| App  | Image              | Replicas | Access          |
|------|--------------------|----------|-----------------|
| app1 | kchaouki/app1:1.0  | 1        | http://app1.com |
| app2 | kchaouki/app2:1.0  | 3        | http://app2.com |
| app3 | kchaouki/app3:1.0  | 1        | any other host  |

### Ingress Routing

```
http://app1.com  →  app1-service (port 80)
http://app2.com  →  app2-service (port 80)
(default)        →  app3-service (port 80)
```

### Setup

```bash
cd p2
vagrant up
```

The provisioning script (`scripts/script.sh`) installs K3s, waits for the node to be Ready, applies all manifests from `confs/`, and adds `app1.com` / `app2.com` to `/etc/hosts`.

### Verify

```bash
vagrant ssh kchaoukiS
curl http://app1.com        # → app1 response
curl http://app2.com        # → app2 response
curl http://192.168.56.110  # → app3 response (default backend)
```

---

## Part 3 — K3d with ArgoCD (GitOps)

A local Kubernetes cluster running inside Docker (via K3d), with ArgoCD watching a public GitHub repository and automatically deploying changes to the `dev` namespace.

### Architecture

```
GitHub repo (manifests)
        |
        | (poll every ~3 min)
        v
    ArgoCD (argocd namespace)
        |
        | (kubectl apply)
        v
  App deployment (dev namespace)
        |
        v
Traefik ingress → http://localhost:8888
```

### Ports

| Service  | URL                     |
|----------|-------------------------|
| App      | http://localhost:8888   |
| ArgoCD   | https://localhost:9090  |

### Namespaces

| Namespace | Contents                     |
|-----------|------------------------------|
| argocd    | ArgoCD control plane         |
| dev       | Application workloads        |

### Setup

```bash
cd p3
./scripts/setup.sh
```

The script:
1. Installs k3d if not present
2. Creates a k3d cluster named `mycluster` with port mappings `8888:80` and `9090:443`
3. Creates namespaces `argocd` and `dev`
4. Installs ArgoCD from the official manifests
5. Patches ArgoCD to run in insecure mode (HTTP) for Traefik TLS termination
6. Applies `confs/app-argo.yaml` — the ArgoCD Application pointing to the GitHub repo
7. Applies ingress rules for ArgoCD and the dev app
8. Prints the ArgoCD admin password

### GitOps Demo

1. Check the running app version:
   ```bash
   curl http://localhost:8888/
   # → {"status":"ok", "message": "v1"}
   ```

2. Edit `deployment.yml` in the watched GitHub repo — change `v1` to `v2`, commit and push.

3. Wait for ArgoCD to poll (up to ~3 minutes) or force a sync:
   ```bash
   argocd app sync rrhnizar-app-sample
   ```

4. Verify the update:
   ```bash
   curl http://localhost:8888/
   # → {"status":"ok", "message": "v2"}
   ```

### ArgoCD Login

```bash
# Get the auto-generated admin password
kubectl get secret argocd-initial-admin-secret -n argocd \
  -o jsonpath='{.data.password}' | base64 -d

# Login via CLI
argocd login localhost:9090 --username admin --password <password> --insecure
```

---

## Bonus — ArgoCD + Gitea (Self-hosted Git)

Extends Part 3 by replacing GitHub with a **self-hosted Gitea** instance running inside the cluster. ArgoCD watches the internal Gitea repository over the cluster-internal DNS name.

### Ports

| Service  | URL                     |
|----------|-------------------------|
| App      | http://localhost:8888   |
| ArgoCD   | https://localhost:9090  |
| Gitea    | http://localhost:3000   |

### Additional Components

| Component | Namespace | Install method |
|-----------|-----------|----------------|
| Gitea     | gitea     | Helm chart     |

### Setup

```bash
cd bonus
./scripts/setup.sh
```

The script adds to the Part 3 setup:
- Creates a `gitea` namespace
- Installs Gitea using the official Helm chart (`gitea-charts/gitea`)
- Configures Gitea admin credentials (`root` / `admin1234`)
- Sets `ROOT_URL` to `http://localhost:3000/`

### ArgoCD Application (Bonus)

The ArgoCD Application in `bonus/confs/app-argo.yaml` uses the cluster-internal Gitea URL:

```
repoURL: http://gitea-http.gitea.svc.cluster.local:3000/root/argocd_app_rrhnizar.git
```

This means ArgoCD communicates with Gitea entirely within the cluster over internal DNS, without going through the host network.

### Gitea Credentials

| Field    | Value      |
|----------|------------|
| Username | root       |
| Password | admin1234  |
| URL      | http://localhost:3000 |

---

## Key Concepts

### K3s vs K3d

| | K3s | K3d |
|---|---|---|
| What it is | Lightweight Kubernetes distro | Tool to run K3s inside Docker |
| Node type | Real VM or bare-metal | Docker container |
| Used in | Parts 1 & 2 | Parts 3 & Bonus |
| Cluster lifetime | Persistent (VM) | Ephemeral (seconds to create/delete) |

### GitOps Flow

```
Git commit (manifest change)
    → ArgoCD detects diff (Git ≠ cluster)
        → ArgoCD applies manifest (kubectl apply)
            → Kubernetes pulls new image
                → Pods replaced with new version
```

### Traefik Ingress

K3s and K3d both ship with Traefik as the default ingress controller:

```
curl http://localhost:8888
  → K3d load balancer (port 80)
    → Traefik (reads Ingress rules)
      → ClusterIP Service
        → Pod
```

---

## Useful Commands

### Vagrant (Parts 1 & 2)

```bash
vagrant up           # start and provision VMs
vagrant ssh <name>   # SSH into a VM
vagrant halt         # stop VMs
vagrant destroy -f   # delete VMs
vagrant status       # show VM states
```

### kubectl

```bash
kubectl get nodes                        # list cluster nodes
kubectl get pods -n dev                  # list pods in dev namespace
kubectl get pods -A                      # list pods in all namespaces
kubectl get ingress -A                   # list all ingress rules
kubectl describe pod <name> -n <ns>      # debug a pod
kubectl logs <pod> -n <ns>               # view pod logs
kubectl apply -f <file>                  # apply a manifest
kubectl delete -f <file>                 # delete resources from manifest
kubectl get ns                           # list namespaces
```

### k3d

```bash
k3d cluster list                         # list clusters
k3d cluster create mycluster            # create a cluster
k3d cluster delete mycluster            # delete a cluster
```

### ArgoCD

```bash
argocd app list                          # list all applications
argocd app get <app-name>                # show app status
argocd app sync <app-name>               # force immediate sync
argocd app wait <app-name>               # wait for sync to complete
```

### Helm

```bash
helm repo add <name> <url>               # add a chart repository
helm repo update                         # update chart index
helm install <release> <chart> -n <ns>  # install a chart
helm list -n <ns>                        # list installed releases
helm uninstall <release> -n <ns>        # remove a release
```
