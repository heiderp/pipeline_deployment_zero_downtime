# ─────────────────────────────────────────────────────────────
# Terraform: outputs
# ─────────────────────────────────────────────────────────────

output "vpc_id" {
  description = "VPC ID"
  value       = module.vpc.vpc_id
}

output "private_subnet_ids" {
  description = "Private subnet IDs"
  value       = module.vpc.private_subnets
}

output "public_subnet_ids" {
  description = "Public subnet IDs"
  value       = module.vpc.public_subnets
}

output "alb_dns_name" {
  description = "ALB DNS name"
  value       = aws_lb.main.dns_name
}

output "ecs_cluster_name" {
  description = "ECS cluster name"
  value       = aws_ecs_cluster.main.name
}

output "ecs_cluster_arn" {
  description = "ECS cluster ARN"
  value       = aws_ecs_cluster.main.arn
}

output "alb_listener_arn" {
  description = "ALB listener ARN"
  value       = aws_lb_listener.main.arn
}

output "flask_listener_rule_arn" {
  description = "Flask listener rule ARN"
  value       = aws_lb_listener_rule.flask.arn
}

output "node_listener_rule_arn" {
  description = "Node listener rule ARN"
  value       = aws_lb_listener_rule.node.arn
}

output "spring_listener_rule_arn" {
  description = "Spring listener rule ARN"
  value       = aws_lb_listener_rule.spring.arn
}

output "flask_blue_tg_arn" {
  description = "Flask blue target group ARN"
  value       = aws_lb_target_group.flask_blue.arn
}

output "flask_green_tg_arn" {
  description = "Flask green target group ARN"
  value       = aws_lb_target_group.flask_green.arn
}

output "node_blue_tg_arn" {
  description = "Node blue target group ARN"
  value       = aws_lb_target_group.node_blue.arn
}

output "node_green_tg_arn" {
  description = "Node green target group ARN"
  value       = aws_lb_target_group.node_green.arn
}

output "spring_blue_tg_arn" {
  description = "Spring blue target group ARN"
  value       = aws_lb_target_group.spring_blue.arn
}

output "spring_green_tg_arn" {
  description = "Spring green target group ARN"
  value       = aws_lb_target_group.spring_green.arn
}

output "rds_endpoint" {
  description = "RDS endpoint"
  value       = aws_db_instance.main.endpoint
}

output "rds_port" {
  description = "RDS port"
  value       = aws_db_instance.main.port
}

output "sqs_queue_url" {
  description = "SQS tasks queue URL"
  value       = aws_sqs_queue.tasks.url
}

output "sqs_queue_arn" {
  description = "SQS tasks queue ARN"
  value       = aws_sqs_queue.tasks.arn
}

output "sqs_dlq_url" {
  description = "SQS dead-letter queue URL"
  value       = aws_sqs_queue.tasks_dlq.url
}

output "sns_topic_arn" {
  description = "SNS events topic ARN"
  value       = aws_sns_topic.events.arn
}

output "ecs_task_execution_role_arn" {
  description = "ECS task execution role ARN"
  value       = aws_iam_role.ecs_task_execution.arn
}

output "ecs_task_role_arn" {
  description = "ECS task role ARN"
  value       = aws_iam_role.ecs_task.arn
}

output "ecr_flask_url" {
  description = "ECR repository URL for Flask app"
  value       = aws_ecr_repository.flask.repository_url
}

output "ecr_node_url" {
  description = "ECR repository URL for Node app"
  value       = aws_ecr_repository.node.repository_url
}

output "ecr_spring_url" {
  description = "ECR repository URL for Spring app"
  value       = aws_ecr_repository.spring.repository_url
}

output "rollback_lambda_arn" {
  description = "Rollback Lambda function ARN"
  value       = aws_lambda_function.rollback.arn
}

output "flask_service_name" {
  description = "Flask ECS service name"
  value       = aws_ecs_service.flask.name
}

output "node_service_name" {
  description = "Node ECS service name"
  value       = aws_ecs_service.node.name
}

output "spring_service_name" {
  description = "Spring ECS service name"
  value       = aws_ecs_service.spring.name
}
