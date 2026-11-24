data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.region

  # Terraform の外で作る SSM パラメータ。scripts/setup-ssm-parameters.sh が、同じ名前で作る
  host_key_parameter_name         = "/${var.resource_prefix}/host-key"
  user_public_keys_parameter_name = "/${var.resource_prefix}/user-public-keys"

  # aws_eip には arn 属性がないため、allocation_id から組み立てる
  eip_arn = "arn:aws:ec2:${local.region}:${local.account_id}:elastic-ip/${aws_eip.bastion.allocation_id}"
}

# --- Security Group ---

resource "aws_security_group" "bastion" {
  name        = "${var.resource_prefix}-bastion"
  description = "Security group for the bastion"
  vpc_id      = var.vpc_id
}

resource "aws_vpc_security_group_ingress_rule" "ssh" {
  for_each = toset(var.allowed_cidrs)

  security_group_id = aws_security_group.bastion.id
  description       = "SSH from allowed CIDR"
  cidr_ipv4         = each.value
  ip_protocol       = "tcp"
  from_port         = var.ssh_port
  to_port           = var.ssh_port
}

# Terraform で作る Security Group には、全許可の egress が付かないため、明示して付ける
resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.bastion.id
  description       = "Allow all outbound"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# DB 側の Security Group 本体には触れず、踏み台からの ingress ルールだけを足す
resource "aws_vpc_security_group_ingress_rule" "db_from_bastion" {
  security_group_id            = var.db_security_group_id
  description                  = "DB access from the bastion"
  referenced_security_group_id = aws_security_group.bastion.id
  ip_protocol                  = "tcp"
  from_port                    = var.db_port
  to_port                      = var.db_port
}

# --- Elastic IP ---

resource "aws_eip" "bastion" {
  domain = "vpc"

  tags = {
    Name = "${var.resource_prefix}-bastion"
    Role = "bastion"
  }
}

# --- Launch Template ---

resource "aws_launch_template" "bastion" {
  name        = "${var.resource_prefix}-bastion"
  description = "Ephemeral bastion"

  # 起動のたびに、最新の Amazon Linux 2023（arm64）の AMI を解決する
  image_id      = "resolve:ssm:/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
  instance_type = var.instance_type

  # OS から shutdown すると Terminate になる。User Data が失敗したときに、自分で消えるため
  instance_initiated_shutdown_behavior = "terminate"

  iam_instance_profile {
    name = aws_iam_instance_profile.bastion.name
  }

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  # ENI は使い回さず、毎回新規に作って、EC2 と一緒に消す。
  # 起動直後の外向き通信のために、一時的なパブリック IP を付ける（EIP の関連付けで置き換わる）
  network_interfaces {
    device_index                = 0
    subnet_id                   = var.public_subnet_id
    security_groups             = [aws_security_group.bastion.id]
    associate_public_ip_address = true
    delete_on_termination       = true
  }

  user_data = base64encode(templatefile("${path.module}/userdata.sh.tftpl", {
    eip_allocation_id               = aws_eip.bastion.allocation_id
    host_key_parameter_name         = local.host_key_parameter_name
    user_public_keys_parameter_name = local.user_public_keys_parameter_name
    cloudwatch_config_parameter     = aws_ssm_parameter.cloudwatch_agent_config.name
    ssh_port                        = var.ssh_port
    db_host                         = var.db_host
    db_port                         = var.db_port
  }))

  # ec2:AssociateAddress の条件（Role タグ）に合わせるため、インスタンスと ENI にタグを付ける
  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "${var.resource_prefix}-bastion"
      Role = "bastion"
    }
  }

  tag_specifications {
    resource_type = "network-interface"
    tags = {
      Name = "${var.resource_prefix}-bastion"
      Role = "bastion"
    }
  }

  tag_specifications {
    resource_type = "volume"
    tags = {
      Name = "${var.resource_prefix}-bastion"
    }
  }

  update_default_version = true
}

# --- ログ ---

# 初期化に失敗した踏み台は自分で消えるため、あとから調べられるよう、ログを CloudWatch Logs に送る
resource "aws_cloudwatch_log_group" "bastion" {
  name              = "${var.resource_prefix}-bastion"
  retention_in_days = 30
}

# CloudWatch エージェントの設定。User Data が fetch-config で取得する
resource "aws_ssm_parameter" "cloudwatch_agent_config" {
  name = "/${var.resource_prefix}/cloudwatch-agent-config"
  type = "String"

  value = jsonencode({
    logs = {
      logs_collected = {
        files = {
          collect_list = [
            {
              # User Data の実行ログ
              file_path       = "/var/log/cloud-init-output.log"
              log_group_name  = aws_cloudwatch_log_group.bastion.name
              log_stream_name = "{instance_id}/user-data"
            },
          ]
        }
        journald = {
          collect_list = [
            {
              # 誰が、いつ、どこから接続したかを見るための sshd のログ
              units           = ["sshd"]
              log_group_name  = aws_cloudwatch_log_group.bastion.name
              log_stream_name = "{instance_id}/sshd"
            },
          ]
        }
      }
    }
  })
}
