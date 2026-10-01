variable "aws_region" {
  description = "AWS region for resources"
  type        = string
  default     = "ap-south-1"
}

variable "acm_domain_name" {
  description = "Domain name for the ACM certificate"
  type        = string
  default     = "arun.isroot.in"
}

variable "route53_zone_name" {
  description = "Route53 zone name for the domain"
  type        = string
  default     = "arun.isroot.in"
}
variable "bucket_prefix" {
  description = "Prefix for the S3 bucket name"
  type        = string
}

variable "environment" {
  description = "Deployment environment"
  type        = string
  default     = "production"
}
