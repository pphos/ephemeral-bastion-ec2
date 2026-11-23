variable "resource_prefix" {
  description = "リソース名の接頭辞。bastion-ec2 のリソースを名前で引くので、bastion-ec2 と同じ値にする"
  type        = string
  default     = "ephemeral-bastion"
}

variable "slack_channel_id" {
  description = "踏み台を操作する Slack の専用チャンネルの ID（C から始まる値）。ほかのチャンネルのコマンドは無視する"
  type        = string

  validation {
    condition     = can(regex("^[A-Z0-9]+$", var.slack_channel_id))
    error_message = "チャンネル ID は、英大文字と数字だけの値（例: C0123ABCD）で指定する。"
  }
}
