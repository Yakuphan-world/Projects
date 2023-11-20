terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "5.25.0"
    }
  }
}

# Configure the AWS Provider
provider "aws" {
  region = "eu-central-1"
}


resource "aws_vpc" "project-vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
}

resource "aws_internet_gateway" "gw" {
  vpc_id = aws_vpc.project-vpc.id
}

resource "aws_subnet" "project_subnet" {
  vpc_id                  = aws_vpc.project-vpc.id
  cidr_block              = "10.0.0.0/24"
  map_public_ip_on_launch = true
  depends_on              = [aws_internet_gateway.gw]
}

resource "aws_instance" "devops" {
  # us-west-2
  ami                    = "ami-0bf8e703278ea0245"
  instance_type          = "t2.micro"
  key_name               = "yakup"
  private_ip             = "10.0.0.12"
  subnet_id              = aws_subnet.project_subnet.id
}

resource "aws_eip" "bar" {
  domain = "vpc"

  instance                  = aws_instance.devops.id
  associate_with_private_ip = "10.0.0.12"
  depends_on                = [aws_internet_gateway.gw]
}
resource "aws_security_group" "allow_tls" {
  name        = "allow_tls"
  description = "Allow TLS inbound traffic"

  ingress {
    description = "TLS from VPC"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
  }

  ingress {
    description = "HTTP from VPC"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
  }
  egress {
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  tags = {
    Name = "allow_tls"
  }
}


resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = "my-dashboard"
  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6

        properties = {
          metrics = [
            [
              "AWS/EC2",
              "CPUUtilization",
              "InstanceId",
              "aws_instance.devops.id"
            ]
          ]
          period = 300
          stat   = "Average"
          region = "eu-central-1"
          title  = "EC2 Instance CPU"
        }
      },
      {
        type   = "text"
        x      = 0
        y      = 7
        width  = 3
        height = 3

        properties = {
          markdown = "Hello world"
        }
      }
    ]
  })
}
