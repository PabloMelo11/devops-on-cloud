locals {
  public_subnet_1a_id = one([for subnet in aws_subnet.public : subnet.id if subnet.availability_zone == "us-east-1a"])
  public_subnet_1b_id = one([for subnet in aws_subnet.public : subnet.id if subnet.availability_zone == "us-east-1b"])
}

resource "aws_subnet" "public" {
  count = length(var.vpc.public_subnets)

  vpc_id                  = aws_vpc.this.id
  cidr_block              = var.vpc.public_subnets[count.index].cidr_block
  availability_zone       = var.vpc.public_subnets[count.index].availability_zone
  map_public_ip_on_launch = var.vpc.public_subnets[count.index].map_public_ip_on_launch

  tags       = merge({ Name = "${var.vpc.name}-${var.vpc.public_subnets[count.index].name}", "kubernetes.io/role/elb" = "1" }, vars.tags)
  depends_on = [aws_vpc.this]
}
