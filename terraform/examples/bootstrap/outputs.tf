output "bucket_name" {
  description = "state 用の S3 バケットの名前"
  value       = aws_s3_bucket.tfstate.id
}
