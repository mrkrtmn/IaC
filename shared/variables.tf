variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "name_prefix" {
  description = "Prefijo común para los recursos compartidos (VPC, cluster, IAM)"
  type        = string
  default     = "botwb"
}

variable "vpc_cidr" {
  description = "CIDR del VPC"
  type        = string
  default     = "10.20.0.0/16"
}
