#!/usr/bin/env bash
# Run the platform locally on kind (no AWS account needed).
#
#   scripts/local-up.sh            # cluster + both services deployed with Helm
#   scripts/local-up.sh --gitops   # cluster + Argo CD, which deploys everything from GitHub
#
# Needs: docker, kind, kubectl, helm.
set -euo pipefail
cd "$(dirname "$0")/.."

CLUSTER=blueprint
MODE=${1:-helm}
# Pin every command to this cluster, so another tool switching the shared kubeconfig
# context mid-run (e.g. a second kind cluster being created) can't redirect us.
CONTEXT=${KUBE_CONTEXT:-kind-blueprint}
kubectl() { command kubectl --context "$CONTEXT" "$@"; }
helm() { command helm --kube-context "$CONTEXT" "$@"; }

if ! kind get clusters | grep -qx "$CLUSTER"; then
  echo "== Creating kind cluster '$CLUSTER'"
  kind create cluster --config local/kind-config.yaml --wait 120s
fi

echo "== Building the sample app image and loading it into kind"
docker build -q -t sample-app:local app >/dev/null
kind load docker-image sample-app:local --name "$CLUSTER" >/dev/null

if [ "$MODE" = "--gitops" ]; then
  exec scripts/bootstrap-argocd.sh local
fi

echo "== Deploying services with Helm (the same chart and values Argo CD uses)"
helm dependency build charts/microservice >/dev/null
for svc in orders payments; do
  helm upgrade --install "$svc" charts/microservice \
    --namespace "$svc" --create-namespace \
    -f "gitops/apps/$svc/values.yaml" -f "gitops/apps/$svc/values-local.yaml" \
    --atomic --wait --timeout 5m
done

kubectl get pods -A -l app.kubernetes.io/part-of=shop -o wide
echo
echo "Try:  kubectl -n orders port-forward svc/orders 8080:80   then  curl localhost:8080/"
echo "Prove zero-downtime rollouts:  scripts/rollout-test.sh orders"
