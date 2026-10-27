#!/usr/bin/env bash
# Install Argo CD on the local kind cluster and let it deploy catalog-api
# from Git (k8s/overlays/gitops), pulling the CI-built image from ECR.
#
#   ./scripts/gitops-setup.sh                 # install + deploy (tracks current branch)
#   ./scripts/gitops-setup.sh refresh-ecr     # renew the ECR pull secret (expires after 12h)
#   ./scripts/gitops-setup.sh uninstall       # remove the Application and Argo CD
#
# Prereqs: the kind cluster from scripts/local-cluster-test.sh is running,
# and `aws sts get-caller-identity` works in this terminal.

set -euo pipefail

CLUSTER=catalog
NS=catalog
ARGO_NS=argocd
ARGOCD_VERSION=v3.5.6
AWS_REGION="${AWS_REGION:-us-east-1}"
REVISION="${REVISION:-$(git rev-parse --abbrev-ref HEAD)}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

for bin in kubectl aws; do
  command -v "$bin" >/dev/null || { echo "missing prerequisite: ${bin}"; exit 1; }
done
kubectl config use-context "kind-${CLUSTER}" >/dev/null

# Registry host is derived at runtime and never printed (it contains the account ID).
ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
REGISTRY="${ACCOUNT}.dkr.ecr.${AWS_REGION}.amazonaws.com"

ecr_secret() {
  kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl -n "$NS" create secret docker-registry ecr-pull \
    --docker-server="$REGISTRY" \
    --docker-username=AWS \
    --docker-password="$(aws ecr get-login-password --region "$AWS_REGION")" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  echo "ECR pull secret 'ecr-pull' created/renewed in namespace ${NS} (valid 12h)."
}

case "${1:-install}" in
  refresh-ecr)
    ecr_secret
    exit 0
    ;;
  uninstall)
    kubectl -n "$ARGO_NS" delete application catalog-api --ignore-not-found
    kubectl delete -n "$ARGO_NS" -f "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml" --ignore-not-found
    kubectl delete namespace "$ARGO_NS" --ignore-not-found
    exit 0
    ;;
  install) ;;
  *) echo "usage: $0 [install|refresh-ecr|uninstall]"; exit 1 ;;
esac

echo "==> Installing Argo CD ${ARGOCD_VERSION}..."
kubectl create namespace "$ARGO_NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
# Server-side apply: the ApplicationSet CRD is too large for client-side apply.
kubectl apply -n "$ARGO_NS" --server-side --force-conflicts \
  -f "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml" >/dev/null

# Keep it light on a laptop: SSO (dex), notifications and ApplicationSets
# aren't needed for this demo.
kubectl -n "$ARGO_NS" scale deploy argocd-dex-server argocd-notifications-controller \
  argocd-applicationset-controller --replicas=0 >/dev/null

echo "==> Waiting for Argo CD (first run downloads images, can take several minutes)..."
kubectl -n "$ARGO_NS" rollout status deploy/argocd-redis --timeout=900s
kubectl -n "$ARGO_NS" rollout status deploy/argocd-repo-server --timeout=900s
kubectl -n "$ARGO_NS" rollout status deploy/argocd-server --timeout=900s
kubectl -n "$ARGO_NS" rollout status statefulset/argocd-application-controller --timeout=900s

# If catalog-api was deployed earlier with kubectl (local-cluster-test.sh),
# remove it so Argo CD owns every resource from a clean start.
if kubectl -n "$NS" get deploy catalog-api >/dev/null 2>&1; then
  TRACKED="$(kubectl -n "$NS" get deploy catalog-api -o jsonpath='{.metadata.annotations.argocd\.argoproj\.io/tracking-id}')"
  if [[ -z "$TRACKED" ]]; then
    echo "==> Removing the kubectl-deployed '${NS}' namespace so Argo CD can own it..."
    kubectl delete namespace "$NS" --wait=true
  fi
fi

echo "==> Creating ECR pull secret..."
ecr_secret

echo "==> Creating the Argo CD Application (tracking branch: ${REVISION})..."
sed -e "s|__REGISTRY__|${REGISTRY}|" -e "s|__REVISION__|${REVISION}|" \
  gitops/catalog-api-application.yaml | kubectl apply -f - >/dev/null

echo "==> Waiting for Argo CD to sync and the app to become healthy..."
for _ in $(seq 1 60); do
  SYNC="$(kubectl -n "$ARGO_NS" get application catalog-api -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
  HEALTH="$(kubectl -n "$ARGO_NS" get application catalog-api -o jsonpath='{.status.health.status}' 2>/dev/null || true)"
  printf '   sync=%s health=%s\n' "${SYNC:-?}" "${HEALTH:-?}"
  [[ "$SYNC" == "Synced" && "$HEALTH" == "Healthy" ]] && break
  sleep 10
done

echo
kubectl -n "$ARGO_NS" get application catalog-api
echo
kubectl -n "$NS" get pods -o custom-columns='POD:.metadata.name,STATUS:.status.phase,IMAGE_TAG:.spec.containers[0].image' \
  | sed -E 's|[0-9]{12}\.dkr\.ecr\.[a-z0-9-]+\.amazonaws\.com/||'

PASS="$(kubectl -n "$ARGO_NS" get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 --decode)"
cat <<MSG

Argo CD UI:
  kubectl -n ${ARGO_NS} port-forward svc/argocd-server 8443:443
  open https://localhost:8443   (accept the self-signed certificate)
  user: admin   password: ${PASS}
MSG