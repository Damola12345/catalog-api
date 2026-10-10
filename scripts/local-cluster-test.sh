#!/usr/bin/env bash
# End-to-end verification of the Kubernetes manifests on a local kind cluster.
#   ./scripts/local-cluster-test.sh          # create cluster, deploy, run checks
#   ./scripts/local-cluster-test.sh cleanup  # delete the cluster
#   ECR_IMAGE=<registry>/catalog-api:sha-<commit> ./scripts/local-cluster-test.sh
#                                            # deploy the CI-built image from ECR instead of building locally


set -euo pipefail

CLUSTER=catalog
NS=catalog
IMAGE=catalog-api:local
HOST=catalog.localtest.me
INGRESS_URL=http://localhost:8080
CALICO_VERSION=v3.28.2
INGRESS_NGINX_VERSION=controller-v1.12.1

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [[ "${1:-}" == "cleanup" ]]; then
  kind delete cluster --name "$CLUSTER"
  exit 0
fi

for bin in docker kind kubectl; do
  command -v "$bin" >/dev/null || { echo "missing prerequisite: $bin"; exit 1; }
done

mkdir -p docs/evidence
exec > >(tee docs/evidence/local-cluster-test.log) 2>&1

BOLD=$'\033[1m'; GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'
PASS=0; FAIL=0
section() { printf '\n%s══════════════════════════════════════════════════════════════\n %s\n══════════════════════════════════════════════════════════════%s\n' "$BOLD" "$1" "$RESET"; }
pass()    { printf '%s✔ PASS%s  %s\n' "$GREEN" "$RESET" "$1"; PASS=$((PASS+1)); }
fail()    { printf '%s✘ FAIL%s  %s\n' "$RED" "$RESET" "$1"; FAIL=$((FAIL+1)); }
# Print the command, then run it, so screenshots show what produced the output.
show()    { printf '%s$ %s%s\n' "$BOLD" "$*" "$RESET"; "$@"; }
# HTTP status code of a request through the ingress (Host header avoids any
# local DNS issues with localtest.me).
status()  { curl -s -o /dev/null -w '%{http_code}' -H "Host: $HOST" "$@"; }

# 
section "SETUP  cluster, CNI (Calico), ingress-nginx, image"

if kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
  echo "cluster '$CLUSTER' already exists — reusing it"
else
  kind create cluster --config scripts/kind-config.yaml
fi
kubectl config use-context "kind-$CLUSTER" >/dev/null

echo "Installing Calico $CALICO_VERSION (enforces NetworkPolicy)…"
kubectl apply -f "https://raw.githubusercontent.com/projectcalico/calico/$CALICO_VERSION/manifests/calico.yaml" >/dev/null
kubectl -n kube-system rollout status ds/calico-node --timeout=900s
kubectl wait --for=condition=Ready nodes --all --timeout=180s

echo "Installing ingress-nginx $INGRESS_NGINX_VERSION…"
kubectl apply -f "https://raw.githubusercontent.com/kubernetes/ingress-nginx/$INGRESS_NGINX_VERSION/deploy/static/provider/kind/deploy.yaml" >/dev/null
kubectl -n ingress-nginx wait --for=condition=Ready pod \
  -l app.kubernetes.io/component=controller --timeout=900s
kubectl -n ingress-nginx wait --for=condition=Complete job --all --timeout=120s 2>/dev/null || true

if [[ -n "${ECR_IMAGE:-}" ]]; then
  # Deploy the exact image CI built, scanned and pushed (no local build).
  # Only the tag is printed: the registry host contains the AWS account ID.
  echo "Pulling CI-built image from ECR (tag: ${ECR_IMAGE##*:}) and loading it into kind…"
  docker pull -q "$ECR_IMAGE" >/dev/null
  docker tag "$ECR_IMAGE" "$IMAGE"
else
  echo "Building $IMAGE from docker/Dockerfile and loading it into kind…"
  # --provenance/--sbom off: attestation manifests make `kind load` fail on
  # Docker Desktop with the containerd image store enabled.
  docker build -q --provenance=false --sbom=false -f docker/Dockerfile \
    --build-arg VERSION="$(git rev-parse --short HEAD 2>/dev/null || echo local)" -t "$IMAGE" .
fi
kind load docker-image "$IMAGE" --name "$CLUSTER"

# 
section "1. DEPLOY  kubectl apply -k k8s/overlays/local"

# Namespace first so PSA labels exist before pods are admitted; the admission
# webhook for ingress-nginx can take a few seconds to accept requests.
for i in 1 2 3 4 5; do
  kubectl apply -k k8s/overlays/local && break
  echo "apply attempt $i failed (webhook warming up?) — retrying in 5s"; sleep 5
done
show kubectl -n "$NS" rollout status deploy/catalog-api --timeout=180s

# 
section "2. RESOURCES  everything the manifests created"

show kubectl get nodes -o wide
echo
show kubectl -n "$NS" get deploy,rs,pods,svc,ingress,networkpolicy,configmap,secret,pdb,sa -o wide
echo
show kubectl get ns "$NS" --show-labels

# 
section "3. DEPLOYMENT SPEC  requests/limits, probes, env from ConfigMap/Secret"

printf '%s$ kubectl -n %s describe deploy catalog-api%s\n' "$BOLD" "$NS" "$RESET"
kubectl -n "$NS" describe deploy catalog-api | sed -n '/Pod Template:/,/Volumes:/p'

POD=$(kubectl -n "$NS" get pod -l app.kubernetes.io/name=catalog-api -o jsonpath='{.items[0].metadata.name}')
echo
echo "Pod security context on $POD:"
kubectl -n "$NS" get pod "$POD" -o jsonpath='{"pod:       "}{.spec.securityContext}{"\ncontainer: "}{.spec.containers[0].securityContext}{"\n"}'

READY=$(kubectl -n "$NS" get deploy catalog-api -o jsonpath='{.status.readyReplicas}')
[[ "$READY" == "2" ]] && pass "2/2 replicas Ready (readiness probe passing)" || fail "expected 2 ready replicas, got '$READY'"
RESTARTS=$(kubectl -n "$NS" get pods -l app.kubernetes.io/name=catalog-api -o jsonpath='{range .items[*]}{.status.containerStatuses[0].restartCount}{" "}{end}')
[[ "$RESTARTS" =~ ^(0\ )+$ ]] && pass "0 restarts (liveness probe passing)" || fail "unexpected restarts: $RESTARTS"

# 
section "4. APP THROUGH THE INGRESS  ($INGRESS_URL, Host: $HOST)"

show curl -s -H "Host: $HOST" "$INGRESS_URL/readyz"; echo
show curl -s -H "Host: $HOST" "$INGRESS_URL/api/v1/items"; echo
show curl -s -H "Host: $HOST" "$INGRESS_URL/api/v1/items/1"; echo
echo

[[ "$(status "$INGRESS_URL/healthz")" == 200 ]] && pass "GET /healthz → 200" || fail "GET /healthz"
[[ "$(status "$INGRESS_URL/readyz")" == 200 ]] && pass "GET /readyz → 200" || fail "GET /readyz"
[[ "$(status "$INGRESS_URL/api/v1/items")" == 200 ]] && pass "GET /api/v1/items → 200" || fail "GET /api/v1/items"
[[ "$(status "$INGRESS_URL/api/v1/items/999")" == 404 ]] && pass "GET /api/v1/items/999 → 404" || fail "GET missing item"

CODE=$(status -X POST -d '{"name":"from-test","price":1.5}' "$INGRESS_URL/api/v1/items")
[[ "$CODE" == 401 ]] && pass "POST without API key → 401 (Secret-backed auth enforced)" || fail "POST without key returned $CODE"

echo
show curl -s -X POST -H "Host: $HOST" -H "X-API-Key: local-test-key" \
  -d '{"name":"from-test","price":1.5}' "$INGRESS_URL/api/v1/items"; echo
CODE=$(status -X POST -H "X-API-Key: local-test-key" -d '{"name":"from-test","price":1.5}' "$INGRESS_URL/api/v1/items")
[[ "$CODE" == 201 ]] && pass "POST with API key from Secret → 201" || fail "POST with key returned $CODE"

# 
section "5. NETWORKPOLICY — INGRESS  only ingress-nginx may reach the pods"

echo "Allowed path (ingress-nginx → pod) was proven in section 4."
echo "Now a pod in the 'default' namespace calls the Service directly:"
echo
set +e
show kubectl run np-ingress-test -n default --rm -i --restart=Never --quiet \
  --image=curlimages/curl:8.10.1 -- \
  curl -sS -m 5 http://catalog-api.catalog.svc.cluster.local/healthz
RC=$?
set -e
echo
[[ $RC -ne 0 ]] && pass "direct pod→Service traffic from another namespace is BLOCKED (curl exit $RC)" \
                || fail "pod in 'default' reached catalog-api — NetworkPolicy not enforced"

# 
section "6. NETWORKPOLICY — EGRESS  catalog-api may only resolve DNS"

# The app image is distroless (no shell), so attach an ephemeral debug
# container: it shares the pod's network namespace, so it is subject to
# exactly the same NetworkPolicy as the app container.
DBG=np-egress-$RANDOM
show kubectl -n "$NS" debug "$POD" --profile=restricted --image=busybox:1.36 \
  --container="$DBG" --attach=false -- sh -c '
    echo "--- DNS lookup (should SUCCEED: egress to kube-dns allowed)";
    nslookup kubernetes.default.svc.cluster.local >/dev/null 2>&1 && echo DNS_OK || echo DNS_BLOCKED;
    # A NetworkPolicy drop shows up as a connection timeout; any other result
    # (success, HTTP error, TLS error) means the packet got through.
    probe() { r=$(wget -q -T 5 -O /dev/null "$1" 2>&1); case "$r" in *"timed out"*) echo "$2_BLOCKED";; *) echo "$2_OPEN ($r)";; esac; };
    echo "--- HTTP to the internet (should be BLOCKED)";
    probe http://example.com INTERNET;
    echo "--- Kubernetes API server on :443 (should be BLOCKED)";
    probe http://kubernetes.default.svc:443 APISERVER'

for _ in $(seq 1 30); do
  STATE=$(kubectl -n "$NS" get pod "$POD" -o jsonpath="{.status.ephemeralContainerStatuses[?(@.name=='$DBG')].state.terminated.reason}")
  [[ -n "$STATE" ]] && break; sleep 2
done
OUT=$(kubectl -n "$NS" logs "$POD" -c "$DBG")
echo "$OUT"
echo
grep -q DNS_OK <<<"$OUT"            && pass "DNS to kube-dns ALLOWED"           || fail "DNS lookup failed"
grep -q INTERNET_BLOCKED <<<"$OUT"  && pass "egress to the internet BLOCKED"    || fail "internet reachable from pod"
grep -q APISERVER_BLOCKED <<<"$OUT" && pass "egress to the K8s API BLOCKED"     || fail "API server reachable from pod"

# 
section "7. ZERO-DOWNTIME ROLLOUT  requests keep succeeding during a restart"

LOG=$(mktemp)
( end=$((SECONDS+45)); while (( SECONDS < end )); do status "$INGRESS_URL/api/v1/items" >>"$LOG"; echo >>"$LOG"; sleep 0.1; done ) &
LOOP=$!
sleep 2
show kubectl -n "$NS" rollout restart deploy/catalog-api
show kubectl -n "$NS" rollout status deploy/catalog-api --timeout=120s
wait "$LOOP"
TOTAL=$(grep -c . "$LOG"); OK=$(grep -c '^200$' "$LOG" || true); BAD=$((TOTAL-OK))
echo
echo "requests during rollout: $TOTAL   200 OK: $OK   errors: $BAD"
grep -v '^200$' "$LOG" | sort | uniq -c || true
rm -f "$LOG"
[[ $BAD -eq 0 ]] && pass "rolling restart with 0 failed requests (readiness drain + maxUnavailable: 0)" \
                 || fail "$BAD failed requests during rollout"
echo
show kubectl -n "$NS" get pods -l app.kubernetes.io/name=catalog-api

# 
section "SUMMARY"
printf '%s%d passed%s, %s%d failed%s\n' "$GREEN" "$PASS" "$RESET" "$([[ $FAIL -gt 0 ]] && echo "$RED" || echo "$GREEN")" "$FAIL" "$RESET"
echo "Full log: docs/evidence/local-cluster-test.log"
echo "Tear down: ./scripts/local-cluster-test.sh cleanup"
[[ $FAIL -eq 0 ]]