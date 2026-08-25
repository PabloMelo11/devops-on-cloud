resource "aws_db_proxy_default_target_group" "main" {
  db_proxy_name = aws_db_proxy.this.name

  # o que sao esses parametros?
  connection_pool_config {
    connection_borrow_timeout    = 120
    max_connections_percent      = 100
    max_idle_connections_percent = 50
  }
}

resource "aws_db_proxy_target" "this" {
  db_cluster_identifier = aws_rds_cluster.this.cluster_identifier
  db_proxy_name         = aws_db_proxy.this.name
  target_group_name     = aws_db_proxy_default_target_group.main.name
}
