output "node_role_name" {
  description = "Set as spec.role in the EC2NodeClass."
  value       = aws_iam_role.node.name
}

output "interruption_queue_name" {
  description = "Set as settings.interruptionQueue in the Karpenter Helm values."
  value       = aws_sqs_queue.interruption.name
}

output "controller_role_arn" {
  value = aws_iam_role.controller.arn
}
