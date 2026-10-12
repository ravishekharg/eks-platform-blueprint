#!/usr/bin/env bash
# Installs Argo CD into the current cluster, registers that cluster as a GitOps target, and
# applies the root app. From then on, Git is the only way to change what runs.
#
#   scripts/bootstrap-argocd.sh local                  # kind
#   scripts/bootstrap-argocd.sh dev aws <queue> <role> # EKS (values from terraform output)
set -euo pipefail
cd "$(dirname "$0")/.."

ENV=${1:?usage: bootstrap-argocd.sh <env> [provider] [karpenter-queue] [karpenter-node-role]}
PROVIDER=${2:-kind}
QUEUE=${3:-}
NODE_ROLE=${4:-}
ARGOCD_CHART_VERSION=7.7.11
# Pin every command to this cluster, so another tool switching the shared kubeconfig
# context mid-run (e.g. a second kind cluster being created) can't redirect us.
CONTEXT=${KUBE_CONTEXT:-kind-blueprint}
kubectl() { command kubectl --context "$CONTEXT" "$@"; }
helm() { command helm --kube-context "$CONTEXT" "$@"; }

echo "== Installing Argo CD"
helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
helm repo update argo >/dev/null
helm upgrade --install argocd argo/argo-cd --version "$ARGOCD_CHART_VERSION" \
  --namespace argocd --create-namespace --wait --timeout 10m \
  --set configs.params."server\.insecure"=true >/dev/null

echo "== Registering this cluster as env=$ENV, provider=$PROVIDER"
# A cluster Secret for the in-cluster API, labelled so the ApplicationSets select it.
kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: in-cluster
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: cluster
    blueprint/managed: "true"
    env: $ENV
    provider: $PROVIDER
  annotations:
    blueprint/karpenter-queue: "$QUEUE"
    blueprint/karpenter-node-role: "$NODE_ROLE"
type: Opaque
stringData:
  name: blueprint-$ENV
  server: https://kubernetes.default.svc
  config: '{"tlsClientConfig":{"insecure":false}}'
EOF

echo "== Registering the Karpenter OCI chart repository"
kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: karpenter-oci
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repository
type: Opaque
stringData:
  type: helm
  name: karpenter
  url: public.ecr.aws/karpenter
  enableOCI: "true"
EOF

echo "== Applying the root app"
kubectl apply -f gitops/bootstrap/root.yaml

echo
echo "Argo CD UI:  kubectl -n argocd port-forward svc/argocd-server 8081:80  →  http://localhost:8081"
echo "Password:    kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
