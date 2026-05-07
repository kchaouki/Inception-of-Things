#!/usr/bin/env bash
set -euo pipefail

# ── Part 3: K3d + ArgoCD full setup ────────────────────────────────────────

CLUSTER_NAME="argocd-cluster"
NAMESPACE_ARGOCD="argocd"
NAMESPACE_DEV="dev"
ARGOCD_VERSION="v2.13.5"

command_exists() { command -v "$1" &>/dev/null; }

echo ""
echo "=========================================="
echo " Step 1: Install dependencies"
echo "=========================================="

if ! command_exists brew; then
  echo "Installing Homebrew..."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi

if ! command_exists kubectl; then
  echo "Installing kubectl..."
  brew install kubectl
else
  echo "kubectl already installed."
fi

if ! command_exists k3d; then
  echo "Installing k3d..."
  brew install k3d
else
  echo "k3d already installed."
fi

if ! command_exists argocd; then
  echo "Installing argocd CLI..."
  brew install argocd
else
  echo "argocd CLI already installed."
fi

echo ""
echo "=========================================="
echo " Step 2: Create K3d cluster"
echo "=========================================="

k3d cluster create "${CLUSTER_NAME}" \
  --agents 2 \
  --port "8080:80@loadbalancer" \
  --port "8443:443@loadbalancer" \
  --port "9090:80@loadbalancer"

k3d kubeconfig merge "${CLUSTER_NAME}" --kubeconfig-merge-default
kubectl config use-context "k3d-${CLUSTER_NAME}"

echo "Nodes:"
kubectl get nodes

echo ""
echo "=========================================="
echo " Step 3: Create namespaces"
echo "=========================================="

kubectl create namespace "${NAMESPACE_ARGOCD}" --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace "${NAMESPACE_DEV}" --dry-run=client -o yaml | kubectl apply -f -

echo "Namespaces:"
kubectl get ns

echo ""
echo "=========================================="
echo " Step 4: Install ArgoCD"
echo "=========================================="

kubectl apply -n "${NAMESPACE_ARGOCD}" \
  -f "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"

echo "Waiting for ArgoCD server (up to 3 min)..."
kubectl rollout status deployment/argocd-server -n "${NAMESPACE_ARGOCD}" --timeout=180s

# Run argocd-server in HTTP mode so Traefik ingress works without TLS
kubectl patch deployment argocd-server -n "${NAMESPACE_ARGOCD}" \
  --type json \
  -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--insecure"}]'

kubectl rollout status deployment/argocd-server -n "${NAMESPACE_ARGOCD}" --timeout=60s

echo ""
echo "=========================================="
echo " Step 5: Apply ArgoCD config and ingress"
echo "=========================================="

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFS_DIR="${SCRIPT_DIR}/../confs"

kubectl patch configmap argocd-cm -n argocd --type merge \
  -p '{"data":{"timeout.reconciliation":"300s"}}'
kubectl apply -f "${CONFS_DIR}/argocd/ingress.yml"

# Add argocd.localhost to /etc/hosts if not already present
if ! grep -q "argocd.localhost" /etc/hosts; then
  echo "Adding argocd.localhost to /etc/hosts (requires sudo)..."
  echo "127.0.0.1 argocd.localhost" | sudo tee -a /etc/hosts
else
  echo "argocd.localhost already in /etc/hosts."
fi

echo ""
echo "=========================================="
echo " Step 6: Register app with ArgoCD"
echo "=========================================="

kubectl apply -f "${CONFS_DIR}/argocd/application.yml"

echo ""
echo "=========================================="
echo " Done!"
echo "=========================================="

ARGOCD_PASS=$(kubectl get secret argocd-initial-admin-secret \
  -n "${NAMESPACE_ARGOCD}" \
  -o jsonpath="{.data.password}" | base64 --decode)

echo ""
echo "  ArgoCD UI : http://argocd.localhost:9090"
echo "  User      : admin"
echo "  Password  : ${ARGOCD_PASS}"
echo ""
echo "  App (dev) : http://localhost:8080"
echo ""
echo "  Namespaces:"
kubectl get ns | grep -E "argocd|dev"
echo ""
echo "  ArgoCD will auto-sync github.com/kchaouki/testArgo every 5 min."
