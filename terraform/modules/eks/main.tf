# An EKS cluster with the decisions a production platform needs made explicit:
# - access is managed with EKS access entries (API), not the aws-auth ConfigMap
# - Kubernetes secrets are envelope-encrypted with a customer-managed KMS key
# - control-plane logs go to CloudWatch with a retention period
# - a small managed "system" node group runs cluster-critical add-ons and Karpenter;
#   Karpenter provisions everything else (see ../karpenter)
# - workloads get AWS permissions through EKS Pod Identity, never through the node role

data "aws_partition" "current" {}

# ---------------------------------------------------------------- cluster IAM role
resource "aws_iam_role" "cluster" {
  name = "${var.cluster_name}-cluster"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "cluster" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKSClusterPolicy"
}

# ---------------------------------------------------------------- secrets encryption
data "aws_caller_identity" "current" {}

resource "aws_kms_key" "secrets" {
  description             = "${var.cluster_name} Kubernetes secrets"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  # Explicit key policy: the account administers the key through IAM; the EKS cluster role
  # gets only the operations envelope encryption needs.
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AccountAdministersKey"
        Effect    = "Allow"
        Principal = { AWS = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root" }
        Action    = "kms:*"
        Resource  = "*"
      },
      {
        Sid       = "EksClusterUsesKey"
        Effect    = "Allow"
        Principal = { AWS = aws_iam_role.cluster.arn }
        Action    = ["kms:Encrypt", "kms:Decrypt", "kms:DescribeKey", "kms:CreateGrant"]
        Resource  = "*"
      },
    ]
  })
  tags = var.tags
}

resource "aws_kms_alias" "secrets" {
  name          = "alias/${var.cluster_name}-secrets"
  target_key_id = aws_kms_key.secrets.key_id
}

resource "aws_cloudwatch_log_group" "cluster" {
  # EKS writes to this exact name; creating it first lets Terraform own the retention.
  name              = "/aws/eks/${var.cluster_name}/cluster"
  retention_in_days = var.log_retention_days
  tags              = var.tags
}

# ---------------------------------------------------------------- cluster
resource "aws_eks_cluster" "this" {
  name     = var.cluster_name
  version  = var.kubernetes_version
  role_arn = aws_iam_role.cluster.arn

  vpc_config {
    subnet_ids              = var.subnet_ids
    endpoint_private_access = true
    endpoint_public_access  = length(var.public_access_cidrs) > 0
    public_access_cidrs     = length(var.public_access_cidrs) > 0 ? var.public_access_cidrs : null
  }

  access_config {
    authentication_mode                         = "API"
    bootstrap_cluster_creator_admin_permissions = false # admins are declared below, explicitly
  }

  encryption_config {
    resources = ["secrets"]
    provider {
      key_arn = aws_kms_key.secrets.arn
    }
  }

  enabled_cluster_log_types = ["api", "audit", "authenticator"]

  upgrade_policy {
    # STANDARD avoids paying for extended support silently: an unupgraded cluster is upgraded
    # automatically at the end of standard support instead of moving to the more expensive tier.
    support_type = var.upgrade_support_type
  }

  tags = var.tags

  depends_on = [
    aws_iam_role_policy_attachment.cluster,
    aws_cloudwatch_log_group.cluster,
  ]
}

# ---------------------------------------------------------------- human / CI access
# Each entry maps an IAM principal (an SSO role, the CI deploy role) to an EKS access policy,
# cluster-wide or limited to namespaces.
resource "aws_eks_access_entry" "admins" {
  for_each      = var.access_entries
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = each.value.principal_arn
  tags          = var.tags
}

resource "aws_eks_access_policy_association" "admins" {
  for_each      = var.access_entries
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = aws_eks_access_entry.admins[each.key].principal_arn
  policy_arn    = "arn:${data.aws_partition.current.partition}:eks::aws:cluster-access-policy/${each.value.policy}"

  access_scope {
    type       = length(each.value.namespaces) > 0 ? "namespace" : "cluster"
    namespaces = length(each.value.namespaces) > 0 ? each.value.namespaces : null
  }
}

# ---------------------------------------------------------------- system node group
resource "aws_iam_role" "node" {
  name = "${var.cluster_name}-system-node"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "ec2.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "node" {
  for_each = toset([
    "AmazonEKSWorkerNodePolicy",
    "AmazonEC2ContainerRegistryReadOnly",
    "AmazonEKS_CNI_Policy",         # kept on the node role for simplicity; move it to Pod Identity for aws-node to tighten further
    "AmazonSSMManagedInstanceCore", # Session Manager instead of SSH
  ])
  role       = aws_iam_role.node.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/${each.value}"
}

resource "aws_launch_template" "system" {
  name_prefix = "${var.cluster_name}-system-"

  metadata_options {
    http_tokens                 = "required" # IMDSv2 only
    http_put_response_hop_limit = 1          # pods can't reach the node's instance credentials
  }

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size = 50
      volume_type = "gp3"
      encrypted   = true
    }
  }

  tag_specifications {
    resource_type = "instance"
    tags          = merge(var.tags, { Name = "${var.cluster_name}-system" })
  }
}

resource "aws_eks_node_group" "system" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "system"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = var.subnet_ids
  ami_type        = "AL2023_x86_64_STANDARD"
  instance_types  = var.system_instance_types
  capacity_type   = "ON_DEMAND" # the nodes that run Karpenter itself should not be Spot

  scaling_config {
    min_size     = var.system_node_count
    max_size     = var.system_node_count + 1
    desired_size = var.system_node_count
  }

  update_config {
    max_unavailable = 1
  }

  launch_template {
    id      = aws_launch_template.system.id
    version = aws_launch_template.system.latest_version
  }

  # Only cluster-critical pods tolerate this taint, so application pods land on
  # Karpenter-managed nodes.
  taint {
    key    = "CriticalAddonsOnly"
    value  = "true"
    effect = "NO_SCHEDULE"
  }

  labels = { "node-role" = "system" }
  tags   = var.tags

  depends_on = [aws_iam_role_policy_attachment.node]

  lifecycle {
    ignore_changes = [scaling_config[0].desired_size]
  }
}

# ---------------------------------------------------------------- add-ons
resource "aws_eks_addon" "pod_identity_agent" {
  cluster_name = aws_eks_cluster.this.name
  addon_name   = "eks-pod-identity-agent"
  tags         = var.tags
}

resource "aws_eks_addon" "vpc_cni" {
  cluster_name = aws_eks_cluster.this.name
  addon_name   = "vpc-cni"
  # Prefix delegation gives each ENI slot a /28, so a node can run many more pods before
  # running out of IPs; enableNetworkPolicy makes the CNI enforce NetworkPolicy objects.
  configuration_values = jsonencode({
    env                 = { ENABLE_PREFIX_DELEGATION = "true", WARM_PREFIX_TARGET = "1" }
    enableNetworkPolicy = "true"
  })
  tags = var.tags
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name = aws_eks_cluster.this.name
  addon_name   = "kube-proxy"
  tags         = var.tags
}

resource "aws_eks_addon" "coredns" {
  cluster_name = aws_eks_cluster.this.name
  addon_name   = "coredns"
  configuration_values = jsonencode({
    tolerations = [{ key = "CriticalAddonsOnly", operator = "Exists" }]
  })
  tags       = var.tags
  depends_on = [aws_eks_node_group.system]
}

# EBS CSI driver with its own IAM role, granted through Pod Identity (no node permissions).
resource "aws_iam_role" "ebs_csi" {
  name               = "${var.cluster_name}-ebs-csi"
  assume_role_policy = local.pod_identity_trust
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

resource "aws_eks_addon" "ebs_csi" {
  cluster_name = aws_eks_cluster.this.name
  addon_name   = "aws-ebs-csi-driver"

  pod_identity_association {
    role_arn        = aws_iam_role.ebs_csi.arn
    service_account = "ebs-csi-controller-sa"
  }

  tags       = var.tags
  depends_on = [aws_eks_node_group.system, aws_eks_addon.pod_identity_agent]
}

locals {
  # The fixed trust policy every Pod Identity role uses: it doesn't name the cluster, so the
  # same role can be associated in several clusters.
  pod_identity_trust = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
}
