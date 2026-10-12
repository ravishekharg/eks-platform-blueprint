#!/usr/bin/env bash
# Runs the Kyverno admission policies against rendered manifests, locally or in CI.
# Every service × environment must pass; the deliberately bad manifests must be rejected.
#
#   scripts/policy-test.sh          # needs helm; downloads the Kyverno CLI to /tmp if missing
set -euo pipefail
cd "$(dirname "$0")/.."

KYVERNO_VERSION=v1.13.2
KYVERNO=${KYVERNO:-/tmp/kyverno}
if [ ! -x "$KYVERNO" ]; then
  curl -sSL "https://github.com/kyverno/kyverno/releases/download/${KYVERNO_VERSION}/kyverno-cli_${KYVERNO_VERSION}_linux_x86_64.tar.gz" \
    | tar xz -C "$(dirname "$KYVERNO")" kyverno
fi
POLICIES=gitops/platform/kyverno-policies/policies.yaml
OUT=$(mktemp -d)

helm dependency build charts/microservice >/dev/null
fail=0

echo "== Every service × environment must pass"
for svc in $(ls gitops/apps); do
  for env in local dev prod; do
    helm template "$svc" charts/microservice -f "gitops/apps/$svc/values.yaml" -f "gitops/apps/$svc/values-$env.yaml" > "$OUT/$svc-$env.yaml"
    if "$KYVERNO" apply "$POLICIES" --resource "$OUT/$svc-$env.yaml" >"$OUT/result.txt" 2>&1 && grep -q "fail: 0," "$OUT/result.txt"; then
      echo "  pass  $svc-$env"
    else
      echo "  FAIL  $svc-$env"; cat "$OUT/result.txt"; fail=1
    fi
  done
done

echo "== Unsafe manifests must be rejected"
# A pod using :latest, with no resources, running as root.
cat > "$OUT/bad-pod.yaml" <<'EOF'
apiVersion: v1
kind: Pod
metadata: { name: bad, namespace: orders }
spec:
  containers:
    - name: app
      image: nginx:latest
EOF
for bad in bad-pod; do
  "$KYVERNO" apply "$POLICIES" --resource "$OUT/$bad.yaml" >"$OUT/result.txt" 2>&1 || true
  if grep -qE "fail: [1-9]" "$OUT/result.txt"; then
    echo "  rejected  $bad ($(grep -oE 'fail: [0-9]+' "$OUT/result.txt"))"
  else
    echo "  NOT REJECTED  $bad"; cat "$OUT/result.txt"; fail=1
  fi
done

# The production replica rule on its own: an otherwise compliant Deployment with 1 replica in a
# namespace labelled env=prod must be rejected by exactly prod-min-replicas.
helm template orders charts/microservice -f gitops/apps/orders/values.yaml --set replicas=1   | python3 -c '
import sys, yaml
for d in yaml.safe_load_all(sys.stdin):
    if d and d.get("kind") == "Deployment":
        d["metadata"]["namespace"] = "orders"
        print(yaml.safe_dump(d))' > "$OUT/one-replica.yaml"
cat > "$OUT/prod-ns-values.yaml" <<'EOF'
apiVersion: cli.kyverno.io/v1alpha1
kind: Value
namespaceSelector:
  - name: orders
    labels: { env: prod }
EOF
"$KYVERNO" apply "$POLICIES" --resource "$OUT/one-replica.yaml" --values-file "$OUT/prod-ns-values.yaml" >"$OUT/result.txt" 2>&1 || true
if grep -q "policy prod-min-replicas -> .* failed" "$OUT/result.txt" && grep -q "fail: 1," "$OUT/result.txt"; then
  echo "  rejected  one-replica prod Deployment (by prod-min-replicas only)"
else
  echo "  NOT REJECTED  one-replica prod Deployment"; cat "$OUT/result.txt"; fail=1
fi

rm -rf "$OUT"
exit $fail
