# Design decisions

Short records of the choices that shape this platform, each with what was given up.

### 1. Own Terraform modules instead of community modules
**Choice:** `terraform/modules/{vpc,eks,karpenter,platform}` are written here.
**Why:** every resource and setting is visible and reviewable; the composition module keeps
environments structurally identical.
**Trade-off:** more code to maintain than `terraform-aws-modules`, which also cover more edge cases.

### 2. Environments are directories, not workspaces
**Why:** separate state, separate accounts and credentials, explicit differences in `.tfvars`,
and the ability to promote a module version dev → prod.
**Trade-off:** a little duplication in the env folders (Terragrunt would remove it at larger scale).

### 3. Access entries, not the aws-auth ConfigMap
**Why:** access is declared in Terraform through the EKS API; no risk of a bad ConfigMap edit
locking everyone out; `bootstrap_cluster_creator_admin_permissions = false` so nobody has access
by accident of having created the cluster.

### 4. EKS Pod Identity, not IRSA
**Why:** no OIDC provider per cluster, one fixed trust policy, roles reusable across clusters.
**Trade-off:** needs the Pod Identity agent add-on; some third-party tools still document IRSA only.

### 5. Small system node group + Karpenter for everything else
**Why:** Karpenter picks instance types per workload, uses Spot with On-Demand fallback, and
consolidates idle capacity: the main cost lever. The system group (On-Demand, tainted
`CriticalAddonsOnly`) runs Karpenter itself, so Karpenter never schedules its own controller.
**Trade-off:** two node-management mechanisms to understand.

### 6. Library chart + one generic microservice chart
**Why:** probes, security context, spreading, PDBs, HPAs, NetworkPolicies and monitoring are
standard for every service and change in one place; a new service is a values file.
**Trade-off:** services with unusual needs must extend the library rather than write free-form YAML.

### 7. No CPU limits, memory limit = request-sized safety net
**Why:** CPU limits cause CFS throttling and latency spikes even when nodes have spare CPU;
memory isn't compressible, so a limit prevents one leak from taking the node down.

### 8. `maxUnavailable: 1` PodDisruptionBudgets
**Why:** a PDB that allows zero disruptions blocks node drains and upgrades forever.

### 9. GitOps pull model (Argo CD) with ApplicationSets
**Why:** CI never holds cluster credentials; drift is reverted (selfHeal); rollback is `git revert`;
a new cluster gets everything by being registered with the right labels.

### 10. Policies enforced twice: in CI and at admission
**Why:** CI gives fast feedback on pull requests; Kyverno at admission catches anything that
bypasses CI (manual applies, third-party charts).

### Checkov checks skipped in CI, and why
Checkov runs on every pull request; these six findings are deliberate and skipped. Two others it
raised were fixed instead (the VPC default security group now denies everything; the KMS key has
an explicit key policy).

| Check | Finding | Why it's skipped |
|---|---|---|
| CKV_AWS_37 | Not all control-plane log types enabled | `api`, `audit` and `authenticator` are on; `controllerManager` and `scheduler` logs are high-volume and rarely needed. Enable them temporarily when debugging those components |
| CKV_AWS_158 | Log groups not encrypted with a customer KMS key | CloudWatch Logs encrypts at rest with AWS-managed keys; a customer key adds cost and key-policy coupling for logs that hold no secrets |
| CKV_AWS_338 | Log retention under 1 year | 30 days by default to control cost; raise `log_retention_days` where compliance requires it |
| CKV_AWS_289, CKV_AWS_355 | Karpenter controller policy uses `"*"` for some actions | `Describe*`, `pricing:GetProducts` and instance-profile actions don't support resource-level permissions; every mutating EC2 action is scoped by tag conditions |
| CKV2_AWS_19 | Elastic IPs not attached to EC2 instances | They are attached to NAT gateways, which is their purpose (false positive) |
