output "domain_name" {
  description = "Domain name of the application"
  value       = "https://${var.route53_zone_name}"
}