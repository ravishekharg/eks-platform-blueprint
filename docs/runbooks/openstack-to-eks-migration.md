# Runbook: migrating services from OpenStack Kubernetes to EKS in waves

How to move a set of production microservices from Kubernetes on OpenStack to this EKS platform
with a phased, low-disruption cutover. Written as a reusable runbook; the same approach applies
to any "old cluster → new cluster" move.

## 1. Assess (before anything moves)

For every service, record in the migration tracker:

| Field | Why it matters |
|---|---|
| Stateless or stateful | Stateless services move first; stateful ones need a data plan |
| Dependencies (calls / called by) | Decides the wave order and the cross-platform connectivity needed |
| Protocols (HTTP, gRPC, TCP, **UDP**) | UDP (e.g. CoAP/LwM2M device traffic) needs an NLB; ALB can't carry it |
| Inbound clients and **IP allow-lists** | Partners or devices that hard-code IPs need stable EIPs (NLB) or Global Accelerator |
| Outbound allow-lists at partners | Give partners the new NAT gateway EIPs (Terraform output `nat_public_ips`) in advance |
| Data stores | Stay where they are for now (reached over VPN/Direct Connect) or move with replication |
| Config and secrets | Move into values files and AWS Secrets Manager (External Secrets) |
| Traffic, SLOs, peak hours | Sets the cutover window and the rollback triggers |

Pattern: this is **replatforming** (same containers, new orchestrator), not a rewrite.

## 2. Prepare the target

1. `terraform apply` the environment (network, cluster, Karpenter).
2. Bootstrap Argo CD (`scripts/bootstrap-argocd.sh prod aws <queue> <role>`).
3. Connectivity back to OpenStack: Site-to-Site VPN or Direct Connect to the old network, with
   routes for the old service and database CIDRs; security groups allowing the paths in the
   dependency map.
4. Push images to ECR (re-tag, same digests) and add each service's values files.
5. Deploy every service to EKS with **zero traffic** and run smoke tests against it directly.

## 3. Move traffic in waves

Wave order: edge/stateless/low-risk services first, core services next, stateful last.

For each wave:
1. **Lower DNS TTLs** on the services' records to 60 s at least 24 hours before.
2. **Weighted routing** (Route 53 weighted records, or weights at the gateway): 5% → 25% → 50%
   → 100% to EKS, holding each step while watching the comparison dashboard: error rate, p95/p99
   latency, saturation, business metrics on old vs new.
3. **Rollback trigger** agreed in advance (e.g. error rate on EKS > old + 0.5% for 5 minutes):
   set the weight back to 0; the old deployment is still running untouched.
4. After 100% for an agreed soak period (e.g. one week including a peak), scale the old
   deployment to zero, then delete it later.

## 4. Stateful services

- Preferred: keep the database where it is during the app migration, then migrate the database
  separately (AWS DMS full load + CDC, or native replication) with a short write freeze at cutover.
- Message brokers: run both, bridge or dual-publish during the move, drain the old one.
- Never move an app and its database in the same step.

## 5. Things that typically go wrong (and the guard)

| Problem | Guard |
|---|---|
| Partner/device IP allow-lists reject the new egress IPs | Send NAT EIPs to partners weeks ahead; test from the new path |
| UDP traffic silently dropped | NLB with UDP listeners and source-IP stickiness; test with real clients |
| Cross-platform latency (EKS service calling an OpenStack dependency) | Move chatty dependencies in the same wave |
| DNS cached longer than the TTL | Lower TTLs early; keep the old side running until traffic is truly gone |
| Config drift between platforms | Values files are the single source; diff rendered manifests old vs new |

## 6. Done means

- 100% traffic on EKS through a peak period within SLO.
- Old deployments scaled to zero, alerts and dashboards pointed at EKS only.
- Runbooks, on-call docs and the dependency map updated.
