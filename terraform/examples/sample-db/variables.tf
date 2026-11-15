variable "resource_prefix" {
  description = "リソース名の接頭辞"
  type        = string
  default     = "ephemeral-bastion"
}

variable "vpc_id" {
  description = "DB を置く既存の VPC の ID"
  type        = string
}

variable "private_subnet_ids" {
  description = "DB サブネットグループに入れる、プライベートサブネットの ID。異なる AZ で 2 つ以上"
  type        = list(string)
}

variable "db_username" {
  description = "RDS のマスターユーザーの名前"
  type        = string
  default     = "postgres"
}

variable "db_password" {
  description = "RDS のマスターパスワード。apply のときだけ使い、state には残らない"
  type        = string
  sensitive   = true
  ephemeral   = true
}

variable "db_password_version" {
  description = "パスワードを変えるときに、値を増やす。write-only の引数は、変更を検出できないため"
  type        = number
  default     = 1
}
