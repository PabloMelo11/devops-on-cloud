resource "aws_docdb_cluster_instance" "this" {
  identifier         = var.document_db_cluster.instance.identifier
  cluster_identifier = aws_docdb_cluster.this.id
  instance_class     = var.document_db_cluster.instance.class
}
