data "aws_iam_policy_document" "assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "bastion" {
  name               = "${var.resource_prefix}-bastion"
  assume_role_policy = data.aws_iam_policy_document.assume_role.json
}

# 管理者が、AWS コンソールの SSM Session Manager で入るために付ける
resource "aws_iam_role_policy_attachment" "ssm_managed_instance_core" {
  role       = aws_iam_role.bastion.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "bastion" {
  statement {
    sid     = "GetSsmParameters"
    actions = ["ssm:GetParameter"]
    resources = [
      "arn:aws:ssm:${local.region}:${local.account_id}:parameter${local.host_key_parameter_name}",
      "arn:aws:ssm:${local.region}:${local.account_id}:parameter${local.user_public_keys_parameter_name}",
      aws_ssm_parameter.cloudwatch_agent_config.arn,
    ]
  }

  statement {
    sid = "PutLogs"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogStreams",
    ]
    resources = ["${aws_cloudwatch_log_group.bastion.arn}:*"]
  }

  statement {
    sid     = "AssociateEip"
    actions = ["ec2:AssociateAddress"]
    resources = [
      local.eip_arn,
      "arn:aws:ec2:${local.region}:${local.account_id}:instance/*",
      "arn:aws:ec2:${local.region}:${local.account_id}:network-interface/*",
    ]

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/Role"
      values   = ["bastion"]
    }
  }
}

resource "aws_iam_role_policy" "bastion" {
  name   = "${var.resource_prefix}-bastion"
  role   = aws_iam_role.bastion.id
  policy = data.aws_iam_policy_document.bastion.json
}

resource "aws_iam_instance_profile" "bastion" {
  name = "${var.resource_prefix}-bastion"
  role = aws_iam_role.bastion.name
}
