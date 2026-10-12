#!/usr/bin/env bash
# Proves (or disproves) that a rolling update drops no requests.
#
# Starts a client pod that calls the service every 50 ms, triggers a rollout of every pod,
# waits for it to finish, then counts responses that weren't HTTP 200.
#
#   scripts/rollout-test.sh orders           # with the platform defaults
#   PRESTOP=1 scripts/rollout-test.sh orders # same test with the preStop sleep cut to 1 s (a control run;
#                                            # failures show up where endpoint removal is slow, e.g. behind an ALB)
set -euo pipefail
SVC=${1:-orders}
NS=$SVC
# Pin every command to this cluster, so another tool switching the shared kubeconfig
# context mid-run (e.g. a second kind cluster being created) can't redirect us.
CONTEXT=${KUBE_CONTEXT:-kind-blueprint}
kubectl() { command kubectl --context "$CONTEXT" "$@"; }
helm() { command helm --kube-context "$CONTEXT" "$@"; }

if [ -n "${PRESTOP:-}" ]; then
  echo "== Setting preStop sleep to ${PRESTOP}s for the comparison run"
  kubectl -n "$NS" patch deploy "$SVC" --type=json \
    -p "[{\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/lifecycle/preStop/sleep/seconds\",\"value\":${PRESTOP}}]" >/dev/null
  kubectl -n "$NS" rollout status deploy "$SVC" --timeout=5m >/dev/null
fi

echo "== Allowing the test client through the service's NetworkPolicy (removed at the end)"
kubectl -n "$NS" apply -f - >/dev/null <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-rollout-test
spec:
  podSelector:
    matchLabels: { app.kubernetes.io/name: $SVC }
  policyTypes: ["Ingress"]
  ingress:
    - from:
        - podSelector:
            matchLabels: { role: rollout-test }
EOF
trap 'kubectl -n "$NS" delete networkpolicy allow-rollout-test --ignore-not-found >/dev/null' EXIT

echo "== Starting the traffic generator"
kubectl -n "$NS" delete pod traffic --ignore-not-found >/dev/null
kubectl -n "$NS" run traffic --image=curlimages/curl:8.11.1 --restart=Never --labels="role=rollout-test" \
  --command -- sh -c "while true; do curl -s -o /dev/null -m 2 -w '%{http_code}\n' http://$SVC.$NS.svc.cluster.local/; sleep 0.05; done" >/dev/null
kubectl -n "$NS" wait --for=condition=Ready pod/traffic --timeout=60s >/dev/null
sleep 5

echo "== Rolling every pod of $SVC"
kubectl -n "$NS" rollout restart deploy "$SVC" >/dev/null
kubectl -n "$NS" rollout status deploy "$SVC" --timeout=5m
sleep 5

RESULTS=$(kubectl -n "$NS" logs traffic)
kubectl -n "$NS" delete pod traffic --wait=false >/dev/null
TOTAL=$(echo "$RESULTS" | grep -c . || true)
FAILED=$(echo "$RESULTS" | grep -vc '^200$' || true)
echo
echo "Requests: $TOTAL   not-200: $FAILED"
echo "$RESULTS" | sort | uniq -c | sort -rn

if [ -n "${PRESTOP:-}" ]; then
  echo "== Restoring the chart's preStop setting"
  kubectl -n "$NS" rollout undo deploy "$SVC" >/dev/null
fi
[ "$FAILED" -eq 0 ]
