data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

# --- bastion-ec2 のリソース ---
# bastion-ec2 の出力や state は使わず、名前とタグで引く。resource_prefix を同じ値にそろえるだけで済む

data "aws_launch_template" "bastion" {
  name = "${var.resource_prefix}-bastion"
}

data "aws_eip" "bastion" {
  tags = {
    Name = "${var.resource_prefix}-bastion"
    Role = "bastion"
  }
}

data "aws_iam_role" "bastion" {
  name = "${var.resource_prefix}-bastion"
}

locals {
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.region

  # Terraform の外で作る SSM パラメータ。scripts/setup-slack-secrets.sh が、同じ名前で作る
  signing_secret_parameter_name = "/${var.resource_prefix}/slack-signing-secret"
  signing_secret_parameter_arn  = "arn:aws:ssm:${local.region}:${local.account_id}:parameter${local.signing_secret_parameter_name}"

  # 実行ロールのポリシーで状態機械を指すため、ARN を名前から組み立てる（状態機械はロールに依存するので、参照すると循環する）
  state_machine_name = "${var.resource_prefix}-slackops"
  state_machine_arn  = "arn:aws:states:${local.region}:${local.account_id}:stateMachine:${local.state_machine_name}"

  launch_template_arn = "arn:aws:ec2:${local.region}:${local.account_id}:launch-template/${data.aws_launch_template.bastion.id}"

  lambda_function_name = "${var.resource_prefix}-slack-command"

  # AWS が公開している Powertools for AWS Lambda（TypeScript）のレイヤー。
  # 版は固定する。上げるときは、lambda/package.json の @aws-lambda-powertools/* の版も一緒に上げる（51 は 2.36.0）
  powertools_layer_arn = "arn:aws:lambda:${local.region}:094274105915:layer:AWSLambdaPowertoolsTypeScriptV2:51"
}

# --- Slack のトークン ---

# HTTP Task の定義には Authorization ヘッダーを書けないので、API Key 方式の接続で、
# キーの名前を Authorization、値を「Bearer <トークン>」にして送る
resource "aws_cloudwatch_event_connection" "slack" {
  name               = "${var.resource_prefix}-slack"
  authorization_type = "API_KEY"

  # Terraform にはダミーの値だけを渡し、本物のトークンは scripts/setup-slack-secrets.sh で登録する（state に残さないため）
  auth_parameters {
    api_key {
      key   = "Authorization"
      value = "Bearer dummy"
    }
  }

  lifecycle {
    # 外すと、次の apply でトークンがダミーに戻り、Slack に投稿できなくなる。
    # また、プロバイダは接続を更新するたびに auth_parameters をまるごと送るので、description などの任意の項目は設定しない
    ignore_changes = [auth_parameters]
  }
}

# --- Step Functions ---

resource "aws_sfn_state_machine" "slackops" {
  name     = local.state_machine_name
  type     = "STANDARD"
  role_arn = aws_iam_role.state_machine.arn

  definition = templatefile("${path.module}/templates/state-machine.asl.json.tftpl", {
    channel_id         = var.slack_channel_id
    connection_arn     = aws_cloudwatch_event_connection.slack.arn
    launch_template_id = data.aws_launch_template.bastion.id
    # 準備完了は、踏み台の公開 IP がこの EIP になったかで判断する
    eip_public_ip = data.aws_eip.bastion.public_ip
  })
}

# --- Lambda（スラッシュコマンドを受ける） ---

# Terraform はビルドをしない。apply の前に lambda/ で pnpm run build を実行し、dist/index.mjs を作っておく
data "archive_file" "lambda" {
  type        = "zip"
  source_file = "${path.module}/lambda/dist/index.mjs"
  output_path = "${path.module}/lambda/dist/lambda.zip"
}

resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/${local.lambda_function_name}"
  retention_in_days = 30
}

resource "aws_lambda_function" "slack_command" {
  function_name = local.lambda_function_name
  role          = aws_iam_role.lambda.arn
  runtime       = "nodejs24.x"
  architectures = ["arm64"]
  handler       = "index.handler"
  memory_size   = 256
  timeout       = 10

  filename    = data.archive_file.lambda.output_path
  code_sha256 = data.archive_file.lambda.output_base64sha256

  layers = [local.powertools_layer_arn]

  environment {
    variables = {
      SIGNING_SECRET_PARAMETER_NAME = local.signing_secret_parameter_name
      SLACK_CHANNEL_ID              = var.slack_channel_id
      STATE_MACHINE_ARN             = aws_sfn_state_machine.slackops.arn
    }
  }

  depends_on = [aws_cloudwatch_log_group.lambda]
}

# Slack は AWS の署名を付けられないので、AuthType=NONE で公開し、Lambda のコードで Slack の署名を確かめる。
# NONE のときは、公開の呼び出しを許すリソースベースポリシーを、プロバイダが作成時に付ける
resource "aws_lambda_function_url" "slack_command" {
  function_name      = aws_lambda_function.slack_command.function_name
  authorization_type = "NONE"
}
