# Runbook: upgrading EKS one minor version

EKS supports each Kubernetes minor version for about 14 months of standard support; after that
the cluster moves to extended support at a much higher price (this platform sets
`upgrade_policy.support_type = STANDARD` so that never happens silently). Upgrades go **one minor
version at a time**, dev first, prod a week later.

## Before (a week ahead)
1. Read the Kubernetes and EKS release notes for the target version.
2. Check for removed/deprecated APIs in what's deployed: **EKS upgrade insights** (console/API)
   and `pluto detect-helm` / `kubent` against the cluster; fix charts first.
3. Check add-on compatibility for the target version: VPC CNI, CoreDNS, kube-proxy, EBS CSI,
   Pod Identity agent (`aws eks describe-addon-versions`), and Karpenter, Argo CD, Kyverno,
   kube-prometheus-stack versions.
4. Confirm every PodDisruptionBudget allows at least one disruption (this platform's library
   chart uses `maxUnavailable: 1`) and every service runs ≥ 2 replicas.

## Upgrade (dev, then prod)
1. Bump `kubernetes_version` in `terraform/envs/<env>/terraform.tfvars`, open a PR, review the
   plan (control plane only), merge, apply. Takes ~10–20 minutes; the API stays available.
2. Upgrade the EKS managed add-ons to the versions recommended for the new minor version.
3. **System node group**: Terraform rolls it (`max_unavailable = 1`), draining nodes one at a time.
4. **Karpenter nodes**: drift detection replaces nodes whose AMI no longer matches the new
   version, within the NodePool disruption budget (10% at a time). Watch with
   `kubectl get nodeclaims -w`.
5. Bump Helm chart versions of add-ons that need it (PRs to `gitops/argocd/platform.yaml`).

## Verify
- `kubectl get nodes` all on the new version; no pods Pending; Argo CD all Synced/Healthy.
- SLO dashboards unchanged through the upgrade.

## Rollback
The control plane can't be downgraded. That's why dev goes first and why add-ons and APIs are
checked beforehand. For node problems, pin the previous AMI in the EC2NodeClass and let
Karpenter replace nodes back. For a high-risk upgrade, use **blue/green clusters**: build a new
cluster on the new version with Terraform, register it in Argo CD (everything redeploys from
Git), shift traffic by weighted DNS, delete the old cluster.
