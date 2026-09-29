output "vpc_id" {
  value = aws_vpc.main.id
}

output "instance_id" {
  value = aws_instance.backend.id
}

output "backend_public_ip" {
  value = aws_instance.backend.public_ip
}

output "backend_url" {
  value = "http://${aws_instance.backend.public_ip}:8000"
}

output "db_host" {
  value = aws_db_instance.main.address
}

output "db_name" {
  value = var.db_name
}

output "db_username" {
  value = var.db_username
}

output "db_password" {
  value     = var.db_password
  sensitive = true
}

output "bucket_name" {
  value      = local.bucket_name
  depends_on = [null_resource.frontend_bucket]
}

output "frontend_url" {
  value = "http://${local.bucket_name}.s3-website-${var.aws_region}.amazonaws.com"
}

output "backend_repo_url" {
  value = var.backend_repo_url
}

output "backend_repo_branch" {
  value = var.backend_repo_branch
}

output "frontend_repo_url" {
  value = var.frontend_repo_url
}

output "frontend_repo_branch" {
  value = var.frontend_repo_branch
}
