output "launch_template_id" {
  description = "踏み台を起動する Launch Template の ID"
  value       = aws_launch_template.bastion.id
}

output "eip_allocation_id" {
  description = "踏み台に関連付ける EIP の割り当て ID"
  value       = aws_eip.bastion.allocation_id
}

output "eip_public_ip" {
  description = "踏み台の固定 IP。利用者の SSH トンネルの接続先"
  value       = aws_eip.bastion.public_ip
}

output "bastion_security_group_id" {
  description = "踏み台の Security Group の ID"
  value       = aws_security_group.bastion.id
}

output "log_group_name" {
  description = "踏み台のログを送る CloudWatch Logs のロググループ名"
  value       = aws_cloudwatch_log_group.bastion.name
}
