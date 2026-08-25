data "aws_vpc" "this" {
  id = var.vpc_resources.vpc

  filter {
    name   = "tag:Name"
    values = [var.vpc_resources.vpc]
  }
}
