terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }

    time = {
      source = "hashicorp/time"
      version = "0.11.2"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

# Security group allowing public access
resource "aws_security_group" "teamcity_sg" {
  name        = "teamcity_sg"
  description = "Allow SSH and TeamCity traffic from anywhere"

  ingress {
    description = "Allow SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Allow TeamCity web UI"
    from_port   = 8111
    to_port     = 8111
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Allow all outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# TeamCity Server
resource "aws_instance" "teamcity_server" {
  ami           = "ami-0c819f65440d5f1d1" # Ubuntu 20.04 LTS in us-east-1
  instance_type = "t3.medium"
  key_name      = "terraform-generated-key" # Replace with your existing EC2 key pair name
  vpc_security_group_ids = [aws_security_group.teamcity_sg.id]

  tags = {
    Name = "TeamCityServer"
  }

  user_data = <<-EOF
              #!/bin/bash
              adduser --disabled-password --gecos "" teamcity
              apt update && apt install wget -y
              cd /opt
              wget https://download.jetbrains.com/teamcity/TeamCity-2022.10.1.tar.gz
              tar xfz TeamCity-2022.10.1.tar.gz
              apt install java-common -y
              wget https://corretto.aws/downloads/latest/amazon-corretto-11-x64-linux-jdk.deb
              dpkg --install amazon-corretto-11-x64-linux-jdk.deb
              chown -R teamcity:teamcity TeamCity
              runuser -l teamcity -c "/opt/TeamCity/bin/runAll.sh start"
              EOF
}

# Wait for server to initialize
resource "time_sleep" "wait_for_teamcity_server" {
  depends_on = [aws_instance.teamcity_server]
  create_duration = "5m"
}

# TeamCity Agents
resource "aws_instance" "teamcity_agent" {
  count         = 2
  ami           = "ami-0c819f65440d5f1d1"
  instance_type = "t3.medium"
  key_name      = "terraform-generated-key"
  vpc_security_group_ids = [aws_security_group.teamcity_sg.id]

  depends_on = [time_sleep.wait_for_teamcity_server]

  tags = {
    Name = "TeamCityAgent-${count.index + 1}"
  }

  user_data = <<-EOF
              #!/bin/bash
              apt-get update -y
              apt-get install -y docker.io
              systemctl start docker
              usermod -aG docker ubuntu
              docker run -d \
                -e SERVER_URL="http://${aws_instance.teamcity_server.public_ip}:8111" \
                -v /data/teamcity_agent/conf:/data/teamcity_agent/conf \
                jetbrains/teamcity-agent
              EOF
}

# Output TeamCity server URL
output "teamcity_server_url" {
  value       = "http://${aws_instance.teamcity_server.public_ip}:8111"
  description = "Public URL to access the TeamCity web interface"
}
