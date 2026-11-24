# --- Lambda の実行ロール ---
# 公開される Lambda には、EC2 を操作する権限を持たせない

data "aws_iam_policy_document" "lambda_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda" {
  name               = local.lambda_function_name
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
}

data "aws_iam_policy_document" "lambda" {
  statement {
    sid       = "StartAndListExecutions"
    actions   = ["states:StartExecution", "states:ListExecutions"]
    resources = [aws_sfn_state_machine.slackops.arn]
  }

  # パラメータは AWS 管理キー（aws/ssm）で暗号化する。このキーはアカウント内の IAM プリンシパルに復号を許しているので、kms:Decrypt は付けない
  statement {
    sid       = "GetSigningSecret"
    actions   = ["ssm:GetParameter"]
    resources = [local.signing_secret_parameter_arn]
  }

  statement {
    sid       = "PutLogs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.lambda.arn}:*"]
  }
}

resource "aws_iam_role_policy" "lambda" {
  name   = local.lambda_function_name
  role   = aws_iam_role.lambda.id
  policy = data.aws_iam_policy_document.lambda.json
}

# --- 状態機械の実行ロール ---

data "aws_iam_policy_document" "state_machine_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["states.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_iam_role" "state_machine" {
  name               = local.state_machine_name
  assume_role_policy = data.aws_iam_policy_document.state_machine_assume_role.json
}

data "aws_iam_policy_document" "state_machine" {
  # bastion-ec2 の Launch Template からの起動に限る。Launch Template にない値を上書きした起動は許さない
  statement {
    sid       = "RunFromLaunchTemplate"
    actions   = ["ec2:RunInstances"]
    resources = ["*"]

    condition {
      test     = "ArnLike"
      variable = "ec2:LaunchTemplate"
      values   = [local.launch_template_arn]
    }

    condition {
      test     = "Bool"
      variable = "ec2:IsLaunchTemplateResource"
      values   = ["true"]
    }
  }

  # Launch Template のタグ付けは、起動と同時のときだけ許す
  statement {
    sid       = "TagOnLaunch"
    actions   = ["ec2:CreateTags"]
    resources = ["arn:aws:ec2:${local.region}:${local.account_id}:*/*"]

    condition {
      test     = "StringEquals"
      variable = "ec2:CreateAction"
      values   = ["RunInstances"]
    }
  }

  statement {
    sid       = "PassBastionRole"
    actions   = ["iam:PassRole"]
    resources = [data.aws_iam_role.bastion.arn]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ec2.amazonaws.com"]
    }
  }

  # Launch Template の resolve:ssm で、最新の AMI を解決するため
  statement {
    sid       = "ResolveAmiParameter"
    actions   = ["ssm:GetParameters"]
    resources = ["arn:aws:ssm:${local.region}::parameter/aws/service/ami-amazon-linux-latest/*"]
  }

  statement {
    sid       = "DescribeInstances"
    actions   = ["ec2:DescribeInstances"]
    resources = ["*"]
  }

  statement {
    sid       = "TerminateBastion"
    actions   = ["ec2:TerminateInstances"]
    resources = ["arn:aws:ec2:${local.region}:${local.account_id}:instance/*"]

    condition {
      test     = "StringEquals"
      variable = "ec2:ResourceTag/Role"
      values   = ["bastion"]
    }
  }

  # HTTP Task で、Slack の chat.postMessage だけを呼ぶ
  statement {
    sid       = "InvokeSlackApi"
    actions   = ["states:InvokeHTTPEndpoint"]
    resources = [local.state_machine_arn]

    condition {
      test     = "StringEquals"
      variable = "states:HTTPMethod"
      values   = ["POST"]
    }

    condition {
      test     = "StringLike"
      variable = "states:HTTPEndpoint"
      values   = ["https://slack.com/api/chat.postMessage"]
    }
  }

  statement {
    sid       = "UseConnection"
    actions   = ["events:RetrieveConnectionCredentials"]
    resources = [aws_cloudwatch_event_connection.slack.arn]
  }

  # 接続が作るシークレットの名前は events!connection/<接続名>/<ID> になる
  statement {
    sid       = "ReadConnectionSecret"
    actions   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    resources = ["arn:aws:secretsmanager:${local.region}:${local.account_id}:secret:events!connection/${aws_cloudwatch_event_connection.slack.name}/*"]
  }
}

resource "aws_iam_role_policy" "state_machine" {
  name   = local.state_machine_name
  role   = aws_iam_role.state_machine.id
  policy = data.aws_iam_policy_document.state_machine.json
}
