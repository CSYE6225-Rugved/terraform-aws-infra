output "rds_endpoint" {
  value       = aws_db_instance.rdsinstance.endpoint
  description = "The endpoint of the RDS instance"
}

output "s3_bucket_name" {
  value = aws_s3_bucket.webapp_bucket.id
}
