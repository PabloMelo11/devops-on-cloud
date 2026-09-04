resource "aws_db_proxy_endpoint" "readonly" {
  db_proxy_name          = aws_db_proxy.this.name
  db_proxy_endpoint_name = var.rds_proxy.read_only_endpoint
  vpc_subnet_ids         = data.aws_subnets.private_subnets.ids
  target_role            = "READ_ONLY"
  vpc_security_group_ids = [aws_security_group.postgresql.id]
  tags                   = var.tags
}
