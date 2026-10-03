variable "aws_region" {
  description = "AWS region to deploy into (set this to whatever region the assessment AWS account/environment uses)"
  type        = string
  default     = "ap-southeast-5"
}

variable "project_name" {
  description = "Short prefix used to name resources (SGs, ALB, target group, RDS, IAM role), so re-running terraform apply doesn't collide with a previous attempt"
  type        = string
  default     = "assessment"
}

variable "db_password" {
  description = "The password for the RDS database. No default on purpose — pass it via -var, a *.tfvars file (gitignored), or TF_VAR_db_password so it never lands in source control."
  type        = string
  sensitive   = true
}
