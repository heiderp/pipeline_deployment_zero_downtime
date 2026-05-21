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
# ALB (Application Load Balancer)
# ─────────────────────────────────────────────────────────────

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

# Blue and Green target groups
resource "aws_lb_target_group" "blue" {
  name        = "${var.environment}-blue-tg"
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

  stickiness {
    type = "lb_cookie"
  }
}

resource "aws_lb_target_group" "green" {
  name        = "${var.environment}-green-tg"
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

  stickiness {
    type = "lb_cookie"
  }
}

# Listener rule with weighted forwarding for canary deployments
resource "aws_lb_listener_rule" "app" {
  listener_arn = aws_lb_listener.main.arn
  priority     = 100

  action {
    type = "forward"
    forward {
      target_group {
        arn    = aws_lb_target_group.blue.arn
        weight = var.blue_weight
      }
      target_group {
        arn    = aws_lb_target_group.green.arn
        weight = var.green_weight
      }
    }
  }

  condition {
    path_pattern {
      values = ["/*"]
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
# ECS Task Definitions & Services
# ─────────────────────────────────────────────────────────────

# Placeholder — actual task definitions and services are environment-specific
# and will reference ECR images built by the pipeline.

# ─────────────────────────────────────────────────────────────
# CloudWatch Dashboard
# ─────────────────────────────────────────────────────────────

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
