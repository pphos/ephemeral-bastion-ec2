output "function_url" {
  description = "Slack アプリのスラッシュコマンドの Request URL に貼る URL"
  value       = aws_lambda_function_url.slack_command.function_url
}

output "connection_name" {
  description = "Slack の Bot トークンを登録する EventBridge の接続の名前"
  value       = aws_cloudwatch_event_connection.slack.name
}

output "state_machine_arn" {
  description = "状態機械の ARN。実行の履歴を調べるときに使う"
  value       = aws_sfn_state_machine.slackops.arn
}

output "signing_secret_parameter_name" {
  description = "Slack の Signing Secret を置く SSM パラメータの名前"
  value       = local.signing_secret_parameter_name
}
