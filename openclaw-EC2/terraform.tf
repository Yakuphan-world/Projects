provider "aws" {
  region = "eu-central-1"
}

# SSH Key
resource "tls_private_key" "openclaw_key" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "generated_key" {
  key_name   = "openclaw-ssh-key"
  public_key = tls_private_key.openclaw_key.public_key_openssh
}

resource "local_file" "ssh_key" {
  content         = tls_private_key.openclaw_key.private_key_pem
  filename        = "openclaw-key.pem"
  file_permission = "0400"
}

# Security Group
resource "aws_security_group" "openclaw_sg" {
  name        = "openclaw-security-group"
  description = "Security rules for OpenClaw AI Agent"

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # OpenClaw Gateway port
  ingress {
    from_port   = 18789
    to_port     = 18789
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# EC2 Instance
resource "aws_instance" "openclaw_server" {

  ami           = "ami-005f97cc4a61dd3b4"
  instance_type = "t3.medium"

  key_name = aws_key_pair.generated_key.key_name

  vpc_security_group_ids = [
    aws_security_group.openclaw_sg.id
  ]

  user_data_replace_on_change = true

  user_data_base64 = base64encode(<<EOF
#!/bin/bash
set -ex

export HOME=/home/ubuntu
export USER=ubuntu

apt-get update -y
apt-get install -y curl git xfsprogs

echo "Installing OpenClaw..."

curl -fsSL https://openclaw.ai/install.sh -o /tmp/install.sh
chmod +x /tmp/install.sh

# run installer as ubuntu user
sudo -u ubuntu bash /tmp/install.sh

# fix PATH so openclaw works in shell
echo 'export PATH=$HOME/.npm-global/bin:$PATH' >> /home/ubuntu/.bashrc

echo "OpenClaw installation finished"
EOF
)

  tags = {
    Name = "OpenClaw-Server"
  }
}

# EBS Volume
resource "aws_ebs_volume" "openclaw_data" {
  availability_zone = aws_instance.openclaw_server.availability_zone
  size              = 8
  type              = "gp3"
}

# Attach disk
resource "aws_volume_attachment" "ebs_att" {
  device_name = "/dev/sdh"
  volume_id   = aws_ebs_volume.openclaw_data.id
  instance_id = aws_instance.openclaw_server.id
}

# SSH output
output "ssh_command" {
  value = "ssh -i openclaw-key.pem -o IdentitiesOnly=yes ubuntu@${aws_instance.openclaw_server.public_ip}"
}