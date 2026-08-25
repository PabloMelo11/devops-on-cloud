variable "region" {
  type    = string
  default = "us-east-1"
}

variable "assume_role" {
  type = object({
    role_arn     = string
    session_name = string
    external_id  = string
  })

  default = {
    role_arn     = "arn:aws:iam::705777573148:role/terraform-role"
    session_name = "nsse-terraform-networking"
    external_id  = "4647ed0f-cdd1-4bea-b131-98d4c2dfc272"
  }
}

variable "tags" {
  type = map(string)

  default = {
    Project     = "nsse"
    Environment = "production"
  }
}

variable "vpc" {
  type = object({
    name                     = string
    cidr_block               = string
    internet_gateway_name    = string
    nat_gateway_name         = string
    public_route_table_name  = string
    private_route_table_name = string
    eip_name                 = string
    public_subnets = list(object({
      name                    = string
      cidr_block              = string
      availability_zone       = string
      map_public_ip_on_launch = bool
    }))
    private_subnets = list(object({
      name                    = string
      cidr_block              = string
      availability_zone       = string
      map_public_ip_on_launch = bool
    }))
  })

  default = {
    name                     = "nsse-production-vpc"
    cidr_block               = "10.0.0.0/24"
    internet_gateway_name    = "internet-gateway"
    nat_gateway_name         = "nat-gateway"
    public_route_table_name  = "public-route-table"
    private_route_table_name = "private-route-table"
    eip_name                 = "nat-gateway-eip"
    public_subnets = [
      {
        name                    = "public-subnet-us-east-1a"
        cidr_block              = "10.0.0.0/27"
        availability_zone       = "us-east-1a"
        map_public_ip_on_launch = true
      },
      {
        name                    = "public-subnet-us-east-1b"
        cidr_block              = "10.0.0.64/27"
        availability_zone       = "us-east-1b"
        map_public_ip_on_launch = true
      }
    ]
    private_subnets = [
      {
        name                    = "private-subnet-us-east-1a"
        cidr_block              = "10.0.0.32/27"
        availability_zone       = "us-east-1a"
        map_public_ip_on_launch = false
      },
      {
        name                    = "private-subnet-us-east-1b"
        cidr_block              = "10.0.0.96/27"
        availability_zone       = "us-east-1b"
        map_public_ip_on_launch = false
      }
    ]
  }
}
