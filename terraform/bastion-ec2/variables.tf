variable "resource_prefix" {
  description = "リソース名の接頭辞"
  type        = string
  default     = "ephemeral-bastion"
}

variable "vpc_id" {
  description = "踏み台を置く既存の VPC の ID"
  type        = string
}

variable "public_subnet_id" {
  description = "踏み台を起動する、パブリックサブネットの ID"
  type        = string
}

variable "allowed_cidrs" {
  description = "踏み台への SSH を許可する接続元の CIDR。個人の IP を含むため、リポジトリには残さない"
  type        = list(string)
}

variable "ssh_port" {
  description = "踏み台の sshd が待ち受けるポート。標準の 22 は使わない"
  type        = number
  default     = 2222
}

variable "instance_type" {
  description = "踏み台の EC2 のインスタンスタイプ。arm64（Graviton）のものを指定する"
  type        = string
  default     = "t4g.micro"
}

variable "db_security_group_id" {
  description = "接続先 DB の Security Group の ID。踏み台からの ingress ルールを、ここに足す"
  type        = string
}

variable "db_host" {
  description = "接続先 DB のホスト名"
  type        = string
}

variable "db_port" {
  description = "接続先 DB のポート"
  type        = number
  default     = 5432
}
