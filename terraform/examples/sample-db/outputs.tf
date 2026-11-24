output "db_security_group_id" {
  description = "DB の Security Group の ID。bastion-ec2 の変数に渡す"
  value       = aws_security_group.db.id
}

output "db_host" {
  description = "DB のホスト名。bastion-ec2 の変数に渡す"
  value       = aws_db_instance.db.address
}

output "db_port" {
  description = "DB のポート。bastion-ec2 の変数に渡す"
  value       = aws_db_instance.db.port
}
