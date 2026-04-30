# Request a public ACM certificate with DNS validation.
#
# After terraform apply, add the CNAME record printed by ACM to your DNS
# provider. The certificate will move to ISSUED status once the record
# propagates (typically a few minutes for Route 53, longer for external DNS).
#
# aws_acm_certificate_validation is intentionally omitted: it would block
# terraform apply indefinitely waiting for DNS propagation. Validate the
# certificate manually, then re-run apply — the ALB HTTPS listener (in
# modules/alb) will be created once the cert_arn output is supplied.

resource "aws_acm_certificate" "main" {
  domain_name       = var.domain_name
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = var.tags
}
