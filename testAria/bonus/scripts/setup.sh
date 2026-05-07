#!/usr/bin/env bash
set -euo pipefail

# ── Bonus: K3d + ArgoCD + Gitea (local Git) ────────────────────────────────

CLUSTER_NAME="argocd-cluster"
ARGOCD_VERSION="v2.13.5"
ARGOCD_SYNC_INTERVAL="300s"        # how often ArgoCD polls the repo (e.g. 60s, 180s, 300s)
GITEA_USER="gitea"
GITEA_PASS="gitea123"
GITEA_EMAIL="admin@gitea.local"
GITEA_REPO="testArgo"
GITEA_URL="http://gitea.localhost:3000"
GITEA_INTERNAL_URL="http://gitea.gitea.svc.cluster.local:3000"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFS_DIR="${SCRIPT_DIR}/../confs"

command_exists() { command -v "$1" &>/dev/null; }

echo ""
echo "=========================================="
echo " Step 1: Install dependencies"
echo "=========================================="

if ! command_exists brew; then
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi
command_exists kubectl || brew install kubectl
command_exists k3d    || brew install k3d
command_exists argocd || brew install argocd
command_exists git    || brew install git

echo "All dependencies installed."

echo ""
echo "=========================================="
echo " Step 2: Create K3d cluster"
echo "=========================================="

k3d cluster create "${CLUSTER_NAME}" \
  --agents 2 \
  --port "8080:80@loadbalancer" \
  --port "8443:443@loadbalancer" \
  --port "9090:80@loadbalancer" \
  --port "3000:80@loadbalancer"

k3d kubeconfig merge "${CLUSTER_NAME}" --kubeconfig-merge-default
kubectl config use-context "k3d-${CLUSTER_NAME}"

kubectl get nodes

echo ""
echo "=========================================="
echo " Step 3: Create namespaces"
echo "=========================================="

for ns in argocd dev gitea; do
  kubectl create namespace "${ns}" --dry-run=client -o yaml | kubectl apply -f -
done

kubectl get ns

echo ""
echo "=========================================="
echo " Step 4: Deploy Gitea"
echo "=========================================="

kubectl apply -f "${CONFS_DIR}/gitea/pvc.yml"
kubectl apply -f "${CONFS_DIR}/gitea/deployment.yml"
kubectl apply -f "${CONFS_DIR}/gitea/service.yml"
kubectl apply -f "${CONFS_DIR}/gitea/ingress.yml"

echo "Waiting for Gitea pod to be ready (up to 3 min)..."
kubectl rollout status deployment/gitea -n gitea --timeout=180s

# Add gitea.localhost to /etc/hosts
if ! grep -q "gitea.localhost" /etc/hosts; then
  echo "127.0.0.1 gitea.localhost" | sudo tee -a /etc/hosts
fi

# Give Gitea a moment to fully initialize
echo "Waiting for Gitea HTTP to be ready..."
for i in $(seq 1 30); do
  if curl -sf "${GITEA_URL}/api/v1/version" &>/dev/null; then
    echo "Gitea is up."
    break
  fi
  sleep 5
done

echo ""
echo "=========================================="
echo " Step 5: Configure Gitea"
echo "=========================================="

# Wait for Gitea to write app.ini (proof that it has fully initialized)
echo "Waiting for Gitea to initialize config..."
for i in $(seq 1 30); do
  if kubectl exec -n gitea deployment/gitea -- test -f /var/lib/gitea/custom/conf/app.ini 2>/dev/null; then
    echo "Config ready."
    break
  fi
  sleep 5
done

# Create admin user via exec (rootless image runs as UID 1000, no root error)
kubectl exec -n gitea deployment/gitea -- \
  gitea admin user create \
    --username "${GITEA_USER}" \
    --password "${GITEA_PASS}" \
    --email "${GITEA_EMAIL}" \
    --admin \
    --must-change-password=false 2>/dev/null && echo "Admin user created." || echo "Admin user already exists."

# Create repo via API
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  -X POST "${GITEA_URL}/api/v1/user/repos" \
  -H "Content-Type: application/json" \
  -u "${GITEA_USER}:${GITEA_PASS}" \
  -d "{\"name\":\"${GITEA_REPO}\",\"private\":false,\"auto_init\":true,\"default_branch\":\"main\"}")

if [ "${HTTP_CODE}" = "201" ]; then
  echo "Repo '${GITEA_REPO}' created."
else
  echo "Repo '${GITEA_REPO}' already exists or created (HTTP ${HTTP_CODE})."
fi

# Push dev manifests to local Gitea
TEMP_DIR=$(mktemp -d)
git clone "http://${GITEA_USER}:${GITEA_PASS}@gitea.localhost:3000/${GITEA_USER}/${GITEA_REPO}.git" "${TEMP_DIR}"
mkdir -p "${TEMP_DIR}/confs/dev"
cp "${CONFS_DIR}/dev/"*.yml "${TEMP_DIR}/confs/dev/"
cd "${TEMP_DIR}"
git config user.email "${GITEA_EMAIL}"
git config user.name "${GITEA_USER}"
git add confs/
git commit -m "add dev manifests" 2>/dev/null || echo "Nothing new to commit."
git push
cd - > /dev/null
rm -rf "${TEMP_DIR}"

echo "Dev manifests pushed to local Gitea."

echo ""
echo "=========================================="
echo " Step 6: Install ArgoCD"
echo "=========================================="

kubectl apply -n argocd \
  -f "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"

echo "Waiting for ArgoCD server (up to 8 min)..."
kubectl rollout status deployment/argocd-server -n argocd --timeout=480s

# Run in insecure (HTTP) mode for Traefik ingress
kubectl patch deployment argocd-server -n argocd \
  --type json \
  -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--insecure"}]'
kubectl rollout status deployment/argocd-server -n argocd --timeout=60s

echo ""
echo "=========================================="
echo " Step 7: Configure ArgoCD"
echo "=========================================="

kubectl patch configmap argocd-cm -n argocd --type merge \
  -p "{\"data\":{\"timeout.reconciliation\":\"${ARGOCD_SYNC_INTERVAL}\"}}"
kubectl apply -f "${CONFS_DIR}/argocd/repo-secret.yml"
kubectl apply -f "${CONFS_DIR}/argocd/ingress.yml"

# Add argocd.localhost to /etc/hosts
if ! grep -q "argocd.localhost" /etc/hosts; then
  echo "127.0.0.1 argocd.localhost" | sudo tee -a /etc/hosts
fi

echo ""
echo "=========================================="
echo " Step 8: Register app with ArgoCD"
echo "=========================================="

kubectl apply -f "${CONFS_DIR}/argocd/application.yml"

echo ""
echo "=========================================="
echo " Done!"
echo "=========================================="

ARGOCD_PASS=$(kubectl get secret argocd-initial-admin-secret \
  -n argocd -o jsonpath="{.data.password}" | base64 --decode)

echo ""
echo "  Gitea   : http://gitea.localhost:3000"
echo "  User    : ${GITEA_USER} / ${GITEA_PASS}"
echo ""
echo "  ArgoCD  : http://argocd.localhost:9090"
echo "  User    : admin / ${ARGOCD_PASS}"
echo ""
echo "  App     : http://localhost:8080"
echo ""
echo "  Namespaces:"
kubectl get ns | grep -E "argocd|dev|gitea"
echo ""
echo "  To switch to v2: edit confs/dev/deployment.yml in Gitea, change v1 → v2"
echo "  ArgoCD will auto-sync within 5 minutes."
