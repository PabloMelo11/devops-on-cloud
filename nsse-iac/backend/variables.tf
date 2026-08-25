variable "region" {
  type    = string
  default = "us-east-1"
}

variable "assume_role" {
  type = object({
    role_arn     = string
    external_id  = string
    session_name = string
  })

  default = {
    role_arn     = "arn:aws:iam::705777573148:role/terraform-role"
    external_id  = "4647ed0f-cdd1-4bea-b131-98d4c2dfc272"
    session_name = "nsse-terraform-backend"
  }
}

variable "tags" {
  type = map(string)

  default = {
    Project     = "nsse"
    Environment = "production"
  }
}

variable "remote_backend" {
  type = object({
    bucket = string
    state_locking = object({
      dynamodb_table_name          = string
      dynamodb_table_billing_mode  = string
      dynamodb_table_hash_key      = string
      dynamodb_table_hash_key_type = string
    })
  })

  default = {
    bucket = "nsse-terraform-state-files-2026"
    state_locking = {
      dynamodb_table_name          = "nsse-terraform-state-locking"
      dynamodb_table_billing_mode  = "PAY_PER_REQUEST"
      dynamodb_table_hash_key      = "LockID"
      dynamodb_table_hash_key_type = "S"
    }
  }
}
