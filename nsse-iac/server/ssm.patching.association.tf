resource "aws_ssm_association" "debian_production" {
  name                = var.debian_production_ssm_association.name
  schedule_expression = var.debian_production_ssm_association.schedule_expression
  association_name    = var.debian_production_ssm_association.association_name
  max_concurrency     = var.debian_production_ssm_association.max_concurrency
  max_errors          = var.debian_production_ssm_association.max_errors

  parameters = {
    Operation    = var.debian_production_ssm_association.parameters.Operation
    RebootOption = var.debian_production_ssm_association.parameters.RebootOption
  }

  output_location {
    s3_bucket_name = aws_s3_bucket.ssm_logs.bucket
    s3_key_prefix  = var.debian_production_ssm_association.output_location.s3_key_prefix
  }

  targets {
    key    = var.debian_production_ssm_association.targets.key
    values = [var.patch_group]
  }
}
