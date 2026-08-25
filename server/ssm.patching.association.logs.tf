resource "aws_s3_bucket" "ssm_logs" {
  bucket        = var.ssm_patching_logs_bucket.name
  force_destroy = var.ssm_patching_logs_bucket.force_destroy
  tags          = var.tags
}

data "aws_iam_policy_document" "allow_access_from_instances" {
  statement {
    principals {
      type        = "AWS"
      identifiers = [aws_iam_role.instance_role.arn]
    }

    actions = [
      "s3:PutObject"
    ]

    resources = [
      "${aws_s3_bucket.ssm_logs.arn}/*"
    ]
  }
}

resource "aws_s3_bucket_policy" "allow_access_from_instances" {
  bucket = aws_s3_bucket.ssm_logs.id
  policy = data.aws_iam_policy_document.allow_access_from_instances.json
}
