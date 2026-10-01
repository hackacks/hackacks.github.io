terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.5"
    }
  }
}

# -----------------------------------------------------------------------------
# Provider Configuration
# -----------------------------------------------------------------------------
provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Environment = var.environment
      ManagedBy   = "Terraform"
    }
  }
}

provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"
}

data "aws_route53_zone" "default" {
  name         = var.route53_zone_name
  private_zone = false
}

data "aws_acm_certificate" "site_cert" {
  provider = aws.us_east_1
  domain   = var.acm_domain_name
  statuses = ["ISSUED"]
}

# -----------------------------------------------------------------------------
# S3 Bucket Setup (Origin)
# -----------------------------------------------------------------------------
resource "random_string" "suffix" {
  length  = 6
  special = false
  upper   = false
}

resource "aws_s3_bucket" "site" {
  bucket        = "${var.bucket_prefix}-${random_string.suffix.result}"
  force_destroy = true
}

# S3 Block Public Access (all public traffic routes through CloudFront)
resource "aws_s3_bucket_public_access_block" "site" {
  bucket = aws_s3_bucket.site.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# -----------------------------------------------------------------------------
# CloudFront Origin Access Control (OAC)
# -----------------------------------------------------------------------------
resource "aws_cloudfront_origin_access_control" "site_oac" {
  name                              = "${var.bucket_prefix}-oac"
  description                       = "OAC for S3 static site"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# AWS Managed Caching Policy (CachingOptimized: maximises edge cache hits)
data "aws_cloudfront_cache_policy" "cache_optimized" {
  name = "Managed-CachingOptimized"
}

# -----------------------------------------------------------------------------
# CloudFront CDN Distribution
# -----------------------------------------------------------------------------
resource "aws_cloudfront_distribution" "site" {
  enabled             = true
  is_ipv6_enabled     = true
  http_version        = "http2and3"
  comment             = "CloudFront distribution for ${var.bucket_prefix}"
  default_root_object = "index.html"

  origin {
    domain_name              = aws_s3_bucket.site.bucket_regional_domain_name
    origin_id                = "s3-${aws_s3_bucket.site.id}"
    origin_access_control_id = aws_cloudfront_origin_access_control.site_oac.id
  }

  default_cache_behavior {
    target_origin_id       = "s3-${aws_s3_bucket.site.id}"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD", "OPTIONS"]
    cached_methods         = ["GET", "HEAD"]
    cache_policy_id        = data.aws_cloudfront_cache_policy.cache_optimized.id
    compress               = true
  }

  custom_error_response {
    error_code         = 403
    response_code      = 200
    response_page_path = "/index.html"
  }

  custom_error_response {
    error_code         = 404
    response_code      = 200
    response_page_path = "/index.html"
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }
  aliases = [var.route53_zone_name]

  viewer_certificate {
    acm_certificate_arn      = data.aws_acm_certificate.site_cert.arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }
}

# -----------------------------------------------------------------------------
# SSM Parameter Store (Stores CloudFront Distribution ID and S3 Bucket Name)
resource "aws_ssm_parameter" "cloudfront_distribution_id" {
  name        = "/portfolio/cloudfront_distribution_id"
  description = "CloudFront Distribution ID for the portfolio site"
  type        = "String"
  value       = aws_cloudfront_distribution.site.id
}

resource "aws_ssm_parameter" "s3_bucket_name" {
  name        = "/portfolio/s3_bucket_name"
  description = "S3 Bucket Name for the portfolio site"
  type        = "String"
  value       = aws_s3_bucket.site.bucket
}

# -----------------------------------------------------------------------------
# Route53 DNS Record (Alias to CloudFront Distribution)
# -----------------------------------------------------------------------------
resource "aws_route53_record" "site_alias" {
  zone_id = data.aws_route53_zone.default.zone_id
  name    = var.route53_zone_name
  type    = "A"
  alias {
    name                   = aws_cloudfront_distribution.site.domain_name
    zone_id                = aws_cloudfront_distribution.site.hosted_zone_id
    evaluate_target_health = false
  }
}

# -----------------------------------------------------------------------------
# S3 Bucket Policy (S3 access to CloudFront OAC)
# -----------------------------------------------------------------------------
resource "aws_s3_bucket_policy" "site_policy" {
  bucket = aws_s3_bucket.site.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowCloudFrontServicePrincipalReadOnly"
        Effect = "Allow"
        Principal = {
          Service = "cloudfront.amazonaws.com"
        }
        Action   = "s3:GetObject"
        Resource = "${aws_s3_bucket.site.arn}/*"
        Condition = {
          StringEquals = {
            "AWS:SourceArn" = aws_cloudfront_distribution.site.arn
          }
        }
      }
    ]
  })
}

# -----------------------------------------------------------------------------
# Getting the github idp from the OIDC provider
# -----------------------------------------------------------------------------
data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}


# -----------------------------------------------------------------------------
# Creation of github actions policy for deployment to s3,invalidation of cloudfront cache and get parameters from ssm
# -----------------------------------------------------------------------------
resource "aws_iam_policy" "portfolio_github_actions_policy" {
  name        = "portfolio-github-actions-policy"
  description = "Policy for GitHub Actions to deploy to S3, invalidate CloudFront cache, and access SSM parameters"
  policy      = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = [
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:GetObject",
          "s3:ListBucket"
        ]
        Resource = [
          aws_s3_bucket.site.arn,
          "${aws_s3_bucket.site.arn}/*"
        ]
      },
      {
        Effect   = "Allow"
        Action   = [
          "cloudfront:CreateInvalidation",
          "cloudfront:GetDistribution",
          "cloudfront:GetDistributionConfig"
        ]
        Resource = aws_cloudfront_distribution.site.arn
      },
      {
        Effect   = "Allow"
        Action   = [
          "ssm:GetParameter",
          "ssm:GetParameters",
          "ssm:GetParametersByPath"
        ]
        Resource = [
          aws_ssm_parameter.cloudfront_distribution_id.arn,
          aws_ssm_parameter.s3_bucket_name.arn
        ]
      }
    ]
  })
}

# -----------------------------------------------------------------------------
# Creation of github actions role for deployment to s3,invalidation of cloudfront cache and get parameters from ssm
# -----------------------------------------------------------------------------
resource "aws_iam_role" "portfolio_github_actions_role" {
  name = "portfolio-github-actions-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = data.aws_iam_openid_connect_provider.github.arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringLike = {
            "token.actions.githubusercontent.com:sub" = "repo:hackacks/hackacks.github.io:*"
          }
        }
      }
    ]
  })
}

# -----------------------------------------------------------------------------
# Attach the policy to the role
# -----------------------------------------------------------------------------
resource "aws_iam_role_policy_attachment" "portfolio_github_actions_role_attachment" {
  role       = aws_iam_role.portfolio_github_actions_role.name
  policy_arn = aws_iam_policy.portfolio_github_actions_policy.arn
}