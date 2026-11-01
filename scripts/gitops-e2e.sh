#!/usr/bin/env bash
# The GitOps path, end to end on kind: Argo CD is installed and given ONLY the root app; everything else (add-ons,
# policies, both services) must arrive from this GitHub repository through the app of apps and ApplicationSets.
# Then: the services must answer, manual drift must be reverted by self-heal, and the Kyverno policies Argo CD
# installed must reject a bad pod. Writes gitops-e2e.json; exits 1 if any check fails.
#
#   scripts/gitops-e2e.sh            (needs docker, kind, kubectl, helm; the repository must be public)
# Note: the ApplicationSets track `main`, so this tests what is on main, not an unmerged branch.
set -euo pipefail
cd "$(dirname "$0")/.."
CONTEXT=${KUBE_CONTEXT:-kind-blueprint}
TIMEOUT=${TIMEOUT:-1200}
k() { command kubectl --context "$CONTEXT" "$@"; }

t0=$(date +%s)
scripts/local-up.sh --gitops

echo "== waiting for every Application to be Synced and Healthy (up to ${TIMEOUT}s)"
end=$((t0 + TIMEOUT))
while :; do
  apps=$(k -n argocd get applications -o json 2>/dev/null || echo '{"items":[]}')
  total=$(echo "$apps" | jq '.items | length')
  ready=$(echo "$apps" | jq '[.items[] | select(.status.sync.status == "Synced" and .status.health.status == "Healthy")] | length')
  services=$(echo "$apps" | jq '[.items[] | select(.metadata.name | test("^(orders|payments)-local$"))] | length')
  if [ "$total" -ge 7 ] && [ "$ready" = "$total" ] && [ "$services" = 2 ]; then break; fi
  if [ "$(date +%s)" -ge "$end" ]; then
    echo "timeout: $ready of $total Applications ready"
    echo "$apps" | jq -r '.items[] | "\(.metadata.name): \(.status.sync.status)/\(.status.health.status) \(.status.conditions // [] | map(.message) | join("; "))"'
    exit 1
  fi
  sleep 10
done
converged=$(( $(date +%s) - t0 ))
app_list=$(echo "$apps" | jq -c '[.items[] | {name: .metadata.name, sync: .status.sync.status, health: .status.health.status}]')
echo "   all $total Applications Synced/Healthy after ${converged}s (cluster creation included)"

echo "== the services answer from the ingress namespace, and default-deny blocks everyone else"
# the test client is an ordinary pod, so it must meet the same Kyverno policies as everything else (immutable tag,
# requests and a memory limit, a readiness probe, non-root): no exemption for tests. The services' NetworkPolicies
# admit only the ingress namespace, monitoring and declared callers, so the same probe runs from two places.
probe_from() {   # probe_from <namespace>: prints "<service> <http code>" per service (000 = no connection)
  local ns=$1
  k create namespace "$ns" >/dev/null 2>&1 || true
  k -n "$ns" apply -f - >/dev/null <<'EOF'
apiVersion: v1
kind: Pod
metadata: { name: probe }
spec:
  restartPolicy: Never
  securityContext: { runAsNonRoot: true, runAsUser: 100, seccompProfile: { type: RuntimeDefault } }
  containers:
    - name: curl
      image: curlimages/curl:8.11.1
      command: ["sh", "-c", 'for s in orders.orders payments.payments; do printf "%s %s\n" "$s" "$(curl -s -o /dev/null -m 5 -w "%{http_code}" http://$s/)"; done']
      resources: { requests: { cpu: 10m, memory: 16Mi }, limits: { memory: 32Mi } }
      readinessProbe: { exec: { command: ["true"] }, periodSeconds: 5 }
      securityContext: { allowPrivilegeEscalation: false, capabilities: { drop: ["ALL"] } }
EOF
  k -n "$ns" wait --for=jsonpath='{.status.phase}'=Succeeded pod/probe --timeout=120s >/dev/null
  k -n "$ns" logs probe
  k -n "$ns" delete pod probe --wait=false >/dev/null
}
answers=$(probe_from ingress-nginx)
blocked=$(probe_from default)
echo "$answers" | sed 's/^/   from ingress-nginx: /'
echo "$blocked" | sed 's/^/   from default:       /'

# time until Argo CD puts something back (self-heal), polling once a second
healed_after() {   # healed_after <seconds limit> <check command...>
  local limit=$1 start
  shift
  start=$(date +%s)
  until "$@" >/dev/null 2>&1; do
    [ $(( $(date +%s) - start )) -ge "$limit" ] && { echo -1; return; }
    sleep 1
  done
  echo $(( $(date +%s) - start ))
}
env_restored() { [ "$(k -n orders get deploy orders -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="ENVIRONMENT")].value}')" = local ]; }

echo "== drift: someone deletes the payments Service and edits the orders Deployment by hand"
k -n payments delete service payments >/dev/null
svc_heal=$(healed_after 300 k -n payments get service payments)
k -n orders set env deploy/orders ENVIRONMENT=hand-edited >/dev/null
env_heal=$(healed_after 300 env_restored)
echo "   Service recreated after ${svc_heal}s, Deployment edit reverted after ${env_heal}s"

echo "== policy: Kyverno (installed by Argo CD) must reject a :latest, unconstrained, root pod"
if denial=$(k -n orders run bad --image=nginx:latest --restart=Never 2>&1); then
  rejected=false
  k -n orders delete pod bad --wait=false >/dev/null 2>&1 || true
else
  rejected=true
fi
echo "   rejected: $rejected"
echo "$denial" | grep -o 'disallow-latest-tag\|require-requests-and-probes\|restrict-privileges' | sort -u | sed 's/^/   policy: /'

jq -n --argjson apps "$app_list" --argjson converged "$converged" --arg answers "$answers" --arg blocked "$blocked" \
  --argjson svc "$svc_heal" --argjson env "$env_heal" --argjson rejected "$rejected" \
  --arg policies "$(echo "$denial" | grep -o 'disallow-latest-tag\|require-requests-and-probes\|restrict-privileges' | sort -u | paste -sd, -)" '{
    applications: $apps,
    converged_after_s: $converged,
    services: ($answers | split("\n") | map(select(length > 0) | split(" ") | {(.[0]): .[1]}) | add),
    from_default_namespace: ($blocked | split("\n") | map(select(length > 0) | split(" ") | {(.[0]): .[1]}) | add),
    self_heal: {service_recreated_after_s: $svc, deployment_edit_reverted_after_s: $env},
    bad_pod_rejected: $rejected,
    rejecting_policies: ($policies | split(",") | map(select(length > 0)))
  }' | tee gitops-e2e.json

ok=1
[ "$(jq '[.services[]] | all(. == "200")' gitops-e2e.json)" = true ] || { echo "FAIL: a service didn't answer 200 from the ingress namespace"; ok=0; }
[ "$(jq '[.from_default_namespace[]] | all(. == "000")' gitops-e2e.json)" = true ] || { echo "FAIL: default-deny let a call from the default namespace through"; ok=0; }
[ "$svc_heal" -ge 0 ] || { echo "FAIL: the deleted Service wasn't recreated"; ok=0; }
[ "$env_heal" -ge 0 ] || { echo "FAIL: the hand edit wasn't reverted"; ok=0; }
[ "$rejected" = true ] || { echo "FAIL: the bad pod was admitted"; ok=0; }
[ "$ok" = 1 ] && echo "== GitOps path verified"
[ "$ok" = 1 ]
