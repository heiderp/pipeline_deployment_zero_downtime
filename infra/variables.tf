# ─────────────────────────────────────────────────────────────
# Terraform: variables
# ─────────────────────────────────────────────────────────────

# ── Required ────────────────────────────────────────────────

variable "aws_region" {
  description = "AWS region for all resources"
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Deployment environment (dev, staging, prod)"
  type        = string

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "Environment must be one of: dev, staging, prod"
  }
}

# ── Terraform State ─────────────────────────────────────────

variable "tf_state_bucket" {
  description = "S3 bucket for remote Terraform state"
  type        = string
}

variable "tf_state_lock_table" {
  description = "DynamoDB table for Terraform state locking"
  type        = string
}

# ── Networking ──────────────────────────────────────────────

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "private_subnet_cidrs" {
  description = "Private subnet CIDR blocks"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "public_subnet_cidrs" {
  description = "Public subnet CIDR blocks"
  type        = list(string)
  default     = ["10.0.101.0/24", "10.0.102.0/24"]
}

# ── RDS ─────────────────────────────────────────────────────

variable "rds_instance_class" {
  description = "RDS instance class"
  type        = string
  default     = "db.t4g.micro"
}

variable "rds_allocated_storage" {
  description = "RDS allocated storage (GB)"
  type        = number
  default     = 20
}

variable "rds_db_name" {
  description = "RDS database name"
  type        = string
  default     = "appdb"
}

variable "rds_username" {
  description = "RDS master username"
  type        = string
  sensitive   = true
}

variable "rds_password" {
  description = "RDS master password"
  type        = string
  sensitive   = true
}

# ── Blue/Green Traffic ──────────────────────────────────────

variable "blue_weight" {
  description = "Traffic weight for blue target group (0-100)"
  type        = number
  default     = 100

  validation {
    condition     = var.blue_weight >= 0 && var.blue_weight <= 100
    error_message = "Weight must be between 0 and 100"
  }
}

variable "green_weight" {
  description = "Traffic weight for green target group (0-100)"
  type        = number
  default     = 0

  validation {
    condition     = var.green_weight >= 0 && var.green_weight <= 100
    error_message = "Weight must be between 0 and 100"
  }
}

# ── Notification ────────────────────────────────────────────

variable "slack_webhook_url" {
  description = "Slack webhook URL for notifications"
  type        = string
  sensitive   = true
  default     = ""
}

# ── ECR Repositories ────────────────────────────────────────

variable "ecr_repo_urls" {
  description = "Map of service names to ECR repository URLs"
  type        = map(string)
  default     = {}
}
