resource "aws_security_group" "db" {
  name        = "${var.resource_prefix}-db"
  description = "Security group for the sample DB"
  vpc_id      = var.vpc_id
}

resource "aws_db_subnet_group" "db" {
  name        = "${var.resource_prefix}-db"
  description = "Subnets for the sample DB"
  subnet_ids  = var.private_subnet_ids
}

resource "aws_db_instance" "db" {
  identifier = "${var.resource_prefix}-db"

  engine         = "postgres"
  engine_version = "18.6"
  # 版を固定するため、マイナーバージョンの自動更新は止める
  auto_minor_version_upgrade = false

  instance_class    = "db.t4g.micro"
  allocated_storage = 20
  storage_type      = "gp3"
  storage_encrypted = true
  multi_az          = false

  username            = var.db_username
  password_wo         = var.db_password
  password_wo_version = var.db_password_version

  db_subnet_group_name   = aws_db_subnet_group.db.name
  vpc_security_group_ids = [aws_security_group.db.id]
  publicly_accessible    = false

  # 検証用の DB なので、terraform destroy ですぐ消せることを優先する
  backup_retention_period = 0
  deletion_protection     = false
  skip_final_snapshot     = true
}
