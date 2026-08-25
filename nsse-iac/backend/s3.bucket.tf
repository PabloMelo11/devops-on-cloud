resource "aws_s3_bucket" "this" {
  bucket        = var.remote_backend.bucket
  force_destroy = true // becareful with this, it will delete all the objects in the bucket
}

resource "aws_s3_bucket_versioning" "this" {
  bucket = aws_s3_bucket.this.id

  versioning_configuration {
    status = "Enabled"
  }
}
