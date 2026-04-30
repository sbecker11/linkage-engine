output "cert_arn" {
  description = "ARN of the ACM certificate. Pass to modules/alb cert_arn after the certificate is ISSUED."
  value       = aws_acm_certificate.main.arn
}

output "domain_name" {
  description = "Domain name the certificate covers."
  value       = aws_acm_certificate.main.domain_name
}

output "dns_validation_records" {
  description = "DNS CNAME records to add to your DNS provider to complete validation."
  value = {
    for dvo in aws_acm_certificate.main.domain_validation_options :
    dvo.domain_name => {
      name  = dvo.resource_record_name
      type  = dvo.resource_record_type
      value = dvo.resource_record_value
    }
  }
}
