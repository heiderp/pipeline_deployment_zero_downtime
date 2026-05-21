# ─────────────────────────────────────────────────────────────
# Terraform: main configuration
# Defines the core AWS infrastructure for the zero-downtime
# deployment pipeline PoC.
# ─────────────────────────────────────────────────────────────

terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Remote state with locking (S3 + DynamoDB)
  backend "s3" {
    bucket         = var.tf_state_bucket
    key            = "${var.environment}/terraform.tfstate"
    region         = var.aws_region
    dynamodb_table = var.tf_state_lock_table
    encrypt        = true
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "pipeline-deployment-zero-downtime"
      Environment = var.environment
      ManagedBy   = "Terraform"
    }
  }
}

# ─────────────────────────────────────────────────────────────
# Networking
# ─────────────────────────────────────────────────────────────

data "aws_availability_zones" "available" {
  state = "available"
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "${var.environment}-vpc"
  cidr = var.vpc_cidr

  azs             = slice(data.aws_availability_zones.available.names, 0, 2)
  private_subnets = var.private_subnet_cidrs
  public_subnets  = var.public_subnet_cidrs

  enable_nat_gateway = true
  single_nat_gateway = var.environment != "prod"

  tags = {
    Environment = var.environment
  }
}

# ─────────────────────────────────────────────────────────────
# ECS Cluster
# ─────────────────────────────────────────────────────────────

resource "aws_ecs_cluster" "main" {
  name = "${var.environment}-cluster"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }
}

# ─────────────────────────────────────────────────────────────
# ECR Repositories
# ─────────────────────────────────────────────────────────────

resource "aws_ecr_repository" "flask" {
  name                 = "${var.environment}-flask-app"
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  force_delete = var.environment != "prod"
}

resource "aws_ecr_repository" "node" {
  name                 = "${var.environment}-node-app"
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  force_delete = var.environment != "prod"
}

resource "aws_ecr_repository" "spring" {
  name                 = "${var.environment}-spring-app"
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  force_delete = var.environment != "prod"
}

# Lifecycle policy: keep last 10 images
resource "aws_ecr_lifecycle_policy" "flask" {
  repository = aws_ecr_repository.flask.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep last 10 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 10
      }
      action = { type = "expire" }
    }]
  })
}

resource "aws_ecr_lifecycle_policy" "node" {
  repository = aws_ecr_repository.node.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep last 10 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 10
      }
      action = { type = "expire" }
    }]
  })
}

resource "aws_ecr_lifecycle_policy" "spring" {
  repository = aws_ecr_repository.spring.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep last 10 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 10
      }
      action = { type = "expire" }
    }]
  })
}

resource "aws_lb" "main" {
  name               = "${var.environment}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = module.vpc.public_subnets
}

resource "aws_lb_listener" "main" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      message_body = "Service unavailable"
      status_code  = 503
    }
  }
}

# Test listener for CodeDeploy Blue/Green (port 8081)
# CodeDeploy routes green traffic here during deployment validation
resource "aws_lb_listener" "test" {
  load_balancer_arn = aws_lb.main.arn
  port              = 8081
  protocol          = "HTTP"

  default_action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      message_body = "Green test listener — OK"
      status_code  = 200
    }
  }
}

# ─────────────────────────────────────────────────────────────
# ALB Target Groups (per-service Blue/Green pairs)
# ─────────────────────────────────────────────────────────────

# ── Flask (monolith) ────────────────────────────────────────

resource "aws_lb_target_group" "flask_blue" {
  name        = "${var.environment}-flask-blue"
  port        = 8080
  protocol    = "HTTP"
  vpc_id      = module.vpc.vpc_id
  target_type = "ip"

  health_check {
    path                = "/health"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
    matcher             = "200"
  }

  stickiness { type = "lb_cookie" }

  tags = { Name = "${var.environment}-flask-blue" }
}

resource "aws_lb_target_group" "flask_green" {
  name        = "${var.environment}-flask-green"
  port        = 8080
  protocol    = "HTTP"
  vpc_id      = module.vpc.vpc_id
  target_type = "ip"

  health_check {
    path                = "/health"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
    matcher             = "200"
  }

  stickiness { type = "lb_cookie" }

  tags = { Name = "${var.environment}-flask-green" }
}

# ── Node (microservice) ─────────────────────────────────────

resource "aws_lb_target_group" "node_blue" {
  name        = "${var.environment}-node-blue"
  port        = 8080
  protocol    = "HTTP"
  vpc_id      = module.vpc.vpc_id
  target_type = "ip"

  health_check {
    path                = "/health"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
    matcher             = "200"
  }

  stickiness { type = "lb_cookie" }

  tags = { Name = "${var.environment}-node-blue" }
}

resource "aws_lb_target_group" "node_green" {
  name        = "${var.environment}-node-green"
  port        = 8080
  protocol    = "HTTP"
  vpc_id      = module.vpc.vpc_id
  target_type = "ip"

  health_check {
    path                = "/health"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
    matcher             = "200"
  }

  stickiness { type = "lb_cookie" }

  tags = { Name = "${var.environment}-node-green" }
}

# ── Spring (microservice) ───────────────────────────────────

resource "aws_lb_target_group" "spring_blue" {
  name        = "${var.environment}-spring-blue"
  port        = 8080
  protocol    = "HTTP"
  vpc_id      = module.vpc.vpc_id
  target_type = "ip"

  health_check {
    path                = "/health"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
    matcher             = "200"
  }

  stickiness { type = "lb_cookie" }

  tags = { Name = "${var.environment}-spring-blue" }
}

resource "aws_lb_target_group" "spring_green" {
  name        = "${var.environment}-spring-green"
  port        = 8080
  protocol    = "HTTP"
  vpc_id      = module.vpc.vpc_id
  target_type = "ip"

  health_check {
    path                = "/health"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
    matcher             = "200"
  }

  stickiness { type = "lb_cookie" }

  tags = { Name = "${var.environment}-spring-green" }
}

# ─────────────────────────────────────────────────────────────
# ALB Listener Rules (path-based routing per service)
# ─────────────────────────────────────────────────────────────

resource "aws_lb_listener_rule" "flask" {
  listener_arn = aws_lb_listener.main.arn
  priority     = 110

  action {
    type = "forward"
    forward {
      target_group {
        arn    = aws_lb_target_group.flask_blue.arn
        weight = var.blue_weight
      }
      target_group {
        arn    = aws_lb_target_group.flask_green.arn
        weight = var.green_weight
      }
    }
  }

  condition {
    path_pattern {
      values = ["/flask/*", "/flask"]
    }
  }
}

resource "aws_lb_listener_rule" "node" {
  listener_arn = aws_lb_listener.main.arn
  priority     = 120

  action {
    type = "forward"
    forward {
      target_group {
        arn    = aws_lb_target_group.node_blue.arn
        weight = var.blue_weight
      }
      target_group {
        arn    = aws_lb_target_group.node_green.arn
        weight = var.green_weight
      }
    }
  }

  condition {
    path_pattern {
      values = ["/node/*", "/node"]
    }
  }
}

resource "aws_lb_listener_rule" "spring" {
  listener_arn = aws_lb_listener.main.arn
  priority     = 130

  action {
    type = "forward"
    forward {
      target_group {
        arn    = aws_lb_target_group.spring_blue.arn
        weight = var.blue_weight
      }
      target_group {
        arn    = aws_lb_target_group.spring_green.arn
        weight = var.green_weight
      }
    }
  }

  condition {
    path_pattern {
      values = ["/spring/*", "/spring"]
    }
  }
}

# ─────────────────────────────────────────────────────────────
# Security Groups
# ─────────────────────────────────────────────────────────────

resource "aws_security_group" "alb" {
  name        = "${var.environment}-alb-sg"
  description = "ALB security group"
  vpc_id      = module.vpc.vpc_id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "ecs_tasks" {
  name        = "${var.environment}-ecs-tasks-sg"
  description = "ECS tasks security group"
  vpc_id      = module.vpc.vpc_id

  ingress {
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ─────────────────────────────────────────────────────────────
# RDS (PostgreSQL)
# ─────────────────────────────────────────────────────────────

resource "aws_db_subnet_group" "main" {
  name       = "${var.environment}-rds-subnet"
  subnet_ids = module.vpc.private_subnets
}

resource "aws_db_instance" "main" {
  identifier = "${var.environment}-rds"

  engine         = "postgres"
  engine_version = "16"
  instance_class = var.rds_instance_class

  allocated_storage = var.rds_allocated_storage
  storage_encrypted = true
  storage_type      = "gp3"

  db_name  = var.rds_db_name
  username = var.rds_username
  password = var.rds_password

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.ecs_tasks.id]

  skip_final_snapshot       = var.environment != "prod"
  final_snapshot_identifier = "${var.environment}-rds-final"

  backup_retention_period = var.environment == "prod" ? 30 : 7
  backup_window           = "03:00-04:00"
  maintenance_window      = "sun:04:00-sun:05:00"

  deletion_protection = var.environment == "prod"
}

# ─────────────────────────────────────────────────────────────
# SQS (queues)
# ─────────────────────────────────────────────────────────────

resource "aws_sqs_queue" "tasks" {
  name                       = "${var.environment}-tasks-queue"
  delay_seconds              = 0
  max_message_size           = 262144
  message_retention_seconds  = 345600
  visibility_timeout_seconds = 30

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.tasks_dlq.arn
    maxReceiveCount     = 3
  })
}

resource "aws_sqs_queue" "tasks_dlq" {
  name = "${var.environment}-tasks-dlq"
}

# ─────────────────────────────────────────────────────────────
# SNS (topics)
# ─────────────────────────────────────────────────────────────

resource "aws_sns_topic" "events" {
  name = "${var.environment}-events-topic"
}

# SQS subscription to SNS so the Spring app can consume events
resource "aws_sns_topic_subscription" "events_to_queue" {
  topic_arn = aws_sns_topic.events.arn
  protocol  = "sqs"
  endpoint  = aws_sqs_queue.tasks.arn
}

resource "aws_sqs_queue_policy" "allow_sns" {
  queue_url = aws_sqs_queue.tasks.id
  policy    = data.aws_iam_policy_document.sqs_sns_policy.json
}

data "aws_iam_policy_document" "sqs_sns_policy" {
  statement {
    effect = "Allow"
    principals {
      type        = "AWS"
      identifiers = ["*"]
    }
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.tasks.arn]
    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [aws_sns_topic.events.arn]
    }
  }
}

# ─────────────────────────────────────────────────────────────
# IAM Roles
# ─────────────────────────────────────────────────────────────

# ECS Task Execution Role (pull images, write logs)
resource "aws_iam_role" "ecs_task_execution" {
  name = "${var.environment}-ecs-task-execution"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "ecs-tasks.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_task_execution" {
  role       = aws_iam_role.ecs_task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# ECS Task Role (access SQS, SNS, RDS)
resource "aws_iam_role" "ecs_task" {
  name = "${var.environment}-ecs-task"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "ecs-tasks.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "ecs_task_access" {
  name = "${var.environment}-ecs-task-access"
  role = aws_iam_role.ecs_task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes",
          "sqs:SendMessage",
        ]
        Resource = [aws_sqs_queue.tasks.arn]
      },
      {
        Effect = "Allow"
        Action = [
          "sns:Publish",
        ]
        Resource = [aws_sns_topic.events.arn]
      },
    ]
  })
}

# ─────────────────────────────────────────────────────────────
# ECS Task Definitions
# ─────────────────────────────────────────────────────────────

locals {
  container_definitions = {
    flask = jsonencode([{
      name         = "flask-app"
      image        = "${aws_ecr_repository.flask.repository_url}:latest"
      portMappings = [{ containerPort = 8080, protocol = "tcp" }]
      environment = [
        { name = "ENVIRONMENT", value = var.environment },
        { name = "AWS_REGION", value = var.aws_region },
        { name = "SNS_TOPIC_ARN", value = aws_sns_topic.events.arn },
        { name = "SQS_QUEUE_URL", value = aws_sqs_queue.tasks.url },
        { name = "DATABASE_URL", value = "postgresql://${var.rds_username}:${var.rds_password}@${aws_db_instance.main.endpoint}/${var.rds_db_name}" },
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.apps.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "flask"
        }
      }
      healthCheck = {
        command     = ["CMD-SHELL", "curl -f http://localhost:8080/health || exit 1"]
        interval    = 30
        timeout     = 5
        retries     = 3
        startPeriod = 15
      }
    }])

    node = jsonencode([{
      name         = "node-app"
      image        = "${aws_ecr_repository.node.repository_url}:latest"
      portMappings = [{ containerPort = 8080, protocol = "tcp" }]
      environment = [
        { name = "NODE_ENV", value = var.environment },
        { name = "AWS_REGION", value = var.aws_region },
        { name = "SQS_QUEUE_URL", value = aws_sqs_queue.tasks.url },
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.apps.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "node"
        }
      }
      healthCheck = {
        command     = ["CMD-SHELL", "wget -qO- http://localhost:8080/health || exit 1"]
        interval    = 30
        timeout     = 5
        retries     = 3
        startPeriod = 15
      }
    }])

    spring = jsonencode([{
      name         = "spring-app"
      image        = "${aws_ecr_repository.spring.repository_url}:latest"
      portMappings = [{ containerPort = 8080, protocol = "tcp" }]
      environment = [
        { name = "ENVIRONMENT", value = var.environment },
        { name = "AWS_REGION", value = var.aws_region },
        { name = "SNS_TOPIC_ARN", value = aws_sns_topic.events.arn },
        { name = "SQS_QUEUE_URL", value = aws_sqs_queue.tasks.url },
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.apps.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "spring"
        }
      }
      healthCheck = {
        command     = ["CMD-SHELL", "wget -qO- http://localhost:8080/health || exit 1"]
        interval    = 30
        timeout     = 5
        retries     = 3
        startPeriod = 30 # Java needs more time
      }
    }])
  }
}

resource "aws_cloudwatch_log_group" "apps" {
  name              = "/ecs/${var.environment}-apps"
  retention_in_days = var.environment == "prod" ? 30 : 7

  tags = {
    Environment = var.environment
  }
}

resource "aws_ecs_task_definition" "flask" {
  family                   = "${var.environment}-flask"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = var.task_cpu
  memory                   = var.task_memory
  execution_role_arn       = aws_iam_role.ecs_task_execution.arn
  task_role_arn            = aws_iam_role.ecs_task.arn
  container_definitions    = local.container_definitions.flask

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "ARM64"
  }
}

resource "aws_ecs_task_definition" "node" {
  family                   = "${var.environment}-node"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = var.task_cpu
  memory                   = var.task_memory
  execution_role_arn       = aws_iam_role.ecs_task_execution.arn
  task_role_arn            = aws_iam_role.ecs_task.arn
  container_definitions    = local.container_definitions.node

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "ARM64"
  }
}

resource "aws_ecs_task_definition" "spring" {
  family                   = "${var.environment}-spring"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = var.task_cpu
  memory                   = var.task_memory
  execution_role_arn       = aws_iam_role.ecs_task_execution.arn
  task_role_arn            = aws_iam_role.ecs_task.arn
  container_definitions    = local.container_definitions.spring

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "ARM64"
  }
}

# ─────────────────────────────────────────────────────────────
# ECS Services
# ─────────────────────────────────────────────────────────────

resource "aws_ecs_service" "flask" {
  name            = "${var.environment}-flask"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.flask.arn
  desired_count   = var.desired_count
  launch_type     = "FARGATE"

  deployment_controller {
    type = "CODE_DEPLOY"
  }

  network_configuration {
    subnets          = module.vpc.private_subnets
    security_groups  = [aws_security_group.ecs_tasks.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.flask_blue.arn
    container_name   = "flask-app"
    container_port   = 8080
  }

  depends_on = [aws_lb_listener_rule.flask]
}

resource "aws_ecs_service" "node" {
  name            = "${var.environment}-node"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.node.arn
  desired_count   = var.desired_count
  launch_type     = "FARGATE"

  deployment_controller {
    type = "CODE_DEPLOY"
  }

  network_configuration {
    subnets          = module.vpc.private_subnets
    security_groups  = [aws_security_group.ecs_tasks.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.node_blue.arn
    container_name   = "node-app"
    container_port   = 8080
  }

  depends_on = [aws_lb_listener_rule.node]
}

resource "aws_ecs_service" "spring" {
  name            = "${var.environment}-spring"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.spring.arn
  desired_count   = var.desired_count
  launch_type     = "FARGATE"

  deployment_controller {
    type = "CODE_DEPLOY"
  }

  network_configuration {
    subnets          = module.vpc.private_subnets
    security_groups  = [aws_security_group.ecs_tasks.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.spring_blue.arn
    container_name   = "spring-app"
    container_port   = 8080
  }

  depends_on = [aws_lb_listener_rule.spring]
}

# ─────────────────────────────────────────────────────────────
# CodeDeploy (Blue/Green orchestration)
# ─────────────────────────────────────────────────────────────

resource "aws_codedeploy_app" "main" {
  name             = "${var.environment}-app"
  compute_platform = "ECS"
}

# CodeDeploy IAM role
resource "aws_iam_role" "codedeploy" {
  name = "${var.environment}-codedeploy"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "codedeploy.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "codedeploy" {
  role       = aws_iam_role.codedeploy.name
  policy_arn = "arn:aws:iam::aws:policy/AWSCodeDeployRoleForECS"
}

# ── Flask deployment group ──────────────────────────────────

resource "aws_codedeploy_deployment_group" "flask" {
  app_name               = aws_codedeploy_app.main.name
  deployment_group_name  = "${var.environment}-flask"
  service_role_arn       = aws_iam_role.codedeploy.arn
  deployment_config_name = "CodeDeployDefault.ECSCanary10Percent5Minutes"

  deployment_style {
    deployment_option = "WITH_TRAFFIC_CONTROL"
    deployment_type   = "BLUE_GREEN"
  }

  ecs_service {
    cluster_name = aws_ecs_cluster.main.name
    service_name = aws_ecs_service.flask.name
  }

  load_balancer_info {
    target_group_pair_info {
      prod_traffic_route {
        listener_arns = [aws_lb_listener.main.arn]
      }
      test_traffic_route {
        listener_arns = [aws_lb_listener.test.arn]
      }
      target_group {
        name = aws_lb_target_group.flask_blue.name
      }
      target_group {
        name = aws_lb_target_group.flask_green.name
      }
    }
  }

  auto_rollback_configuration {
    enabled = true
    events  = ["DEPLOYMENT_FAILURE", "DEPLOYMENT_STOP_ON_ALARM"]
  }

  alarm_configuration {
    alarms = [
      aws_cloudwatch_metric_alarm.high_error_rate.alarm_name,
      aws_cloudwatch_metric_alarm.high_latency.alarm_name,
      aws_cloudwatch_metric_alarm.low_throughput.alarm_name,
    ]
  }
}

# ── Node deployment group ───────────────────────────────────

resource "aws_codedeploy_deployment_group" "node" {
  app_name               = aws_codedeploy_app.main.name
  deployment_group_name  = "${var.environment}-node"
  service_role_arn       = aws_iam_role.codedeploy.arn
  deployment_config_name = "CodeDeployDefault.ECSCanary10Percent5Minutes"

  deployment_style {
    deployment_option = "WITH_TRAFFIC_CONTROL"
    deployment_type   = "BLUE_GREEN"
  }

  ecs_service {
    cluster_name = aws_ecs_cluster.main.name
    service_name = aws_ecs_service.node.name
  }

  load_balancer_info {
    target_group_pair_info {
      prod_traffic_route {
        listener_arns = [aws_lb_listener.main.arn]
      }
      test_traffic_route {
        listener_arns = [aws_lb_listener.test.arn]
      }
      target_group {
        name = aws_lb_target_group.node_blue.name
      }
      target_group {
        name = aws_lb_target_group.node_green.name
      }
    }
  }

  auto_rollback_configuration {
    enabled = true
    events  = ["DEPLOYMENT_FAILURE", "DEPLOYMENT_STOP_ON_ALARM"]
  }

  alarm_configuration {
    alarms = [
      aws_cloudwatch_metric_alarm.high_error_rate.alarm_name,
      aws_cloudwatch_metric_alarm.high_latency.alarm_name,
      aws_cloudwatch_metric_alarm.low_throughput.alarm_name,
    ]
  }
}

# ── Spring deployment group ─────────────────────────────────

resource "aws_codedeploy_deployment_group" "spring" {
  app_name               = aws_codedeploy_app.main.name
  deployment_group_name  = "${var.environment}-spring"
  service_role_arn       = aws_iam_role.codedeploy.arn
  deployment_config_name = "CodeDeployDefault.ECSCanary10Percent5Minutes"

  deployment_style {
    deployment_option = "WITH_TRAFFIC_CONTROL"
    deployment_type   = "BLUE_GREEN"
  }

  ecs_service {
    cluster_name = aws_ecs_cluster.main.name
    service_name = aws_ecs_service.spring.name
  }

  load_balancer_info {
    target_group_pair_info {
      prod_traffic_route {
        listener_arns = [aws_lb_listener.main.arn]
      }
      test_traffic_route {
        listener_arns = [aws_lb_listener.test.arn]
      }
      target_group {
        name = aws_lb_target_group.spring_blue.name
      }
      target_group {
        name = aws_lb_target_group.spring_green.name
      }
    }
  }

  auto_rollback_configuration {
    enabled = true
    events  = ["DEPLOYMENT_FAILURE", "DEPLOYMENT_STOP_ON_ALARM"]
  }

  alarm_configuration {
    alarms = [
      aws_cloudwatch_metric_alarm.high_error_rate.alarm_name,
      aws_cloudwatch_metric_alarm.high_latency.alarm_name,
      aws_cloudwatch_metric_alarm.low_throughput.alarm_name,
    ]
  }
}

# ─────────────────────────────────────────────────────────────
# Notification Lambda (CloudWatch alarm → Slack notify)
# ─────────────────────────────────────────────────────────────

resource "aws_iam_role" "notify_lambda" {
  name = "${var.environment}-notify-lambda"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "notify_lambda_basic" {
  role       = aws_iam_role.notify_lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "notify_lambda_sns" {
  name = "${var.environment}-notify-sns"
  role = aws_iam_role.notify_lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["sns:Publish"]
      Resource = [aws_sns_topic.events.arn]
    }]
  })
}

resource "aws_lambda_function" "notify" {
  filename         = "${path.module}/lambda/rollback.zip"
  function_name    = "${var.environment}-alarm-notify"
  role             = aws_iam_role.notify_lambda.arn
  handler          = "notify.handler"
  runtime          = "python3.12"
  timeout          = 30
  source_code_hash = filebase64sha256("${path.module}/lambda/rollback.zip")

  environment {
    variables = {
      ENVIRONMENT = var.environment
      SNS_TOPIC   = aws_sns_topic.events.arn
    }
  }

  tags = { Environment = var.environment }
}

# Allow CloudWatch alarms to invoke the notification Lambda
resource "aws_lambda_permission" "cloudwatch" {
  statement_id  = "AllowCloudWatchAlarm"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.notify.function_name
  principal     = "lambda.alarms.cloudwatch.amazonaws.com"
  source_arn    = "arn:aws:cloudwatch:${var.aws_region}:${data.aws_caller_identity.current.account_id}:alarm:*"
}

data "aws_caller_identity" "current" {}

# ─────────────────────────────────────────────────────────────
# CloudWatch Alarms (notify Lambda via alarm_actions; CodeDeploy handles rollback)
# ─────────────────────────────────────────────────────────────

resource "aws_cloudwatch_metric_alarm" "high_error_rate" {
  alarm_name          = "${var.environment}-Green-HighErrorRate"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "HTTPCode_Target_5XX_Count"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Sum"
  threshold           = var.alarm_error_rate_threshold
  alarm_description   = "High 5XX rate on green — CodeDeploy auto-rolls back, Lambda notifies"
  alarm_actions       = [aws_lambda_function.notify.arn]

  dimensions = {
    LoadBalancer = aws_lb.main.arn_suffix
  }

  tags = {
    Environment = var.environment
  }
}

resource "aws_cloudwatch_metric_alarm" "high_latency" {
  alarm_name          = "${var.environment}-Green-HighLatency"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "TargetResponseTime"
  namespace           = "AWS/ApplicationELB"
  extended_statistic  = "p99"
  period              = 60
  threshold           = var.alarm_latency_threshold_ms
  alarm_description   = "High p99 latency on green — CodeDeploy auto-rolls back, Lambda notifies"
  alarm_actions       = [aws_lambda_function.notify.arn]

  dimensions = {
    LoadBalancer = aws_lb.main.arn_suffix
  }

  tags = {
    Environment = var.environment
  }
}

resource "aws_cloudwatch_metric_alarm" "low_throughput" {
  alarm_name          = "${var.environment}-Green-LowThroughput"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 2
  metric_name         = "RequestCount"
  namespace           = "AWS/ApplicationELB"
  period              = 120
  statistic           = "Sum"
  threshold           = var.alarm_throughput_threshold
  alarm_description   = "Request count dropped — CodeDeploy auto-rolls back, Lambda notifies"
  alarm_actions       = [aws_lambda_function.notify.arn]

  dimensions = {
    LoadBalancer = aws_lb.main.arn_suffix
  }

  tags = {
    Environment = var.environment
  }
}

resource "aws_cloudwatch_metric_alarm" "task_unhealthy" {
  alarm_name          = "${var.environment}-Green-TaskUnhealthy"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 1
  metric_name         = "HealthyHostCount"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Average"
  threshold           = 1
  alarm_description   = "No healthy green tasks — CodeDeploy auto-rolls back, Lambda notifies"
  alarm_actions       = [aws_lambda_function.notify.arn]

  dimensions = {
    LoadBalancer = aws_lb.main.arn_suffix
    TargetGroup  = aws_lb_target_group.flask_green.arn_suffix
  }

  tags = {
    Environment = var.environment
  }
}

resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = "${var.environment}-pipeline-dashboard"
  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6
        properties = {
          metrics = [
            ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", aws_lb.main.name],
            [".", "HTTPCode_Target_5XX_Count", ".", "."],
            [".", "TargetResponseTime", ".", "."],
          ]
          period = 60
          stat   = "Sum"
          region = var.aws_region
          title  = "ALB Metrics"
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 0
        width  = 12
        height = 6
        properties = {
          metrics = [
            ["AWS/ECS", "CPUUtilization", "ClusterName", aws_ecs_cluster.main.name],
            [".", "MemoryUtilization", ".", "."],
          ]
          period = 60
          stat   = "Average"
          region = var.aws_region
          title  = "ECS Cluster Metrics"
        }
      },
    ]
  })
}
