# ACM module tests
#
# Uses mock_provider — no AWS credentials required.
# Run from infra/modules/acm/:
#   terraform init && terraform test

mock_provider "aws" {}

variables {
  domain_name = "linkage.example.com"
  tags = {
    App = "linkage-engine"
    Env = "prod"
  }
}

run "certificate_uses_dns_validation" {
  command = plan

  assert {
    condition     = aws_acm_certificate.main.validation_method == "DNS"
    error_message = "ACM certificate must use DNS validation."
  }
}

run "certificate_domain_matches_variable" {
  command = plan

  assert {
    condition     = aws_acm_certificate.main.domain_name == "linkage.example.com"
    error_message = "Certificate domain must match var.domain_name."
  }
}

run "certificate_is_tagged" {
  command = plan

  assert {
    condition     = aws_acm_certificate.main.tags["App"] == "linkage-engine"
    error_message = "Certificate must carry the App tag."
  }
}

run "output_domain_matches_variable" {
  command = plan

  assert {
    condition     = output.domain_name == "linkage.example.com"
    error_message = "domain_name output must match var.domain_name."
  }
}
