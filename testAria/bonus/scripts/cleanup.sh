#!/usr/bin/env bash
set -euo pipefail

# ── Bonus: full teardown ────────────────────────────────────────────────────

CLUSTER_NAME="argocd-cluster"

command_exists() { command -v "$1" &>/dev/null; }

echo ""
echo "=========================================="
echo " Step 1: Delete K3d cluster"
echo "=========================================="

if command_exists k3d && k3d cluster list | grep -q "^${CLUSTER_NAME}"; then
  k3d cluster delete "${CLUSTER_NAME}"
  echo "Cluster deleted."
else
  echo "Cluster not found, skipping."
fi

echo ""
echo "=========================================="
echo " Step 2: Remove /etc/hosts entries"
echo "=========================================="

for host in argocd.localhost gitea.localhost; do
  if grep -q "${host}" /etc/hosts; then
    sudo sed -i '' "/${host}/d" /etc/hosts
    echo "Removed ${host} from /etc/hosts."
  fi
done

echo ""
echo "=========================================="
echo " Step 3: Uninstall CLI tools"
echo "=========================================="

command_exists argocd && brew uninstall argocd && echo "argocd removed."
command_exists k3d    && brew uninstall k3d    && echo "k3d removed."
brew list kubectl &>/dev/null 2>&1 && brew uninstall kubectl && echo "kubectl removed." || echo "kubectl not managed by Homebrew, skipping."

echo ""
echo "=========================================="
echo " Step 4: Clean up kubeconfig"
echo "=========================================="

[ -f "$HOME/.kube/config" ] && rm -f "$HOME/.kube/config" && echo "Removed ~/.kube/config."

echo ""
echo "=========================================="
echo " Done! Everything removed."
echo "=========================================="
