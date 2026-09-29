resource "random_id" "bucket_suffix" {
  byte_length = 4
}

locals {
  bucket_name = "${var.tag_name}-frontend-bucket-${random_id.bucket_suffix.hex}"

  bucket_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "PublicReadGetObject"
        Effect    = "Allow"
        Principal = "*"
        Action    = "s3:GetObject"
        Resource  = "arn:aws:s3:::${local.bucket_name}/*"
      }
    ]
  })
}

# El bucket policy se escribe a un archivo local para pasárselo a "aws s3api
# put-bucket-policy" sin pelearse con el escapado de comillas dentro de un
# heredoc de shell.
resource "local_file" "bucket_policy" {
  filename = "${path.module}/.generated/${local.bucket_name}-policy.json"
  content  = local.bucket_policy
}

# NOTA IMPORTANTE (AWS Academy):
# El recurso administrado "aws_s3_bucket" del provider AWS (v4+) hace llamadas
# de lectura extra al crearse (GetBucketObjectLockConfiguration,
# GetBucketAccelerateConfiguration, etc.) que el Service Control Policy de
# Organizations de AWS Academy deniega explícitamente, aunque el bucket en sí
# se cree bien. Para no depender de una versión vieja del provider (que rompe
# el state de los demás recursos, ya creados con v5), este bucket se crea y
# configura por fuera del ciclo normal de Terraform, con AWS CLI directamente
# — el mismo enfoque que usaba el script original etapa_3_frontend.sh.
resource "null_resource" "frontend_bucket" {
  triggers = {
    bucket_name = local.bucket_name
    region      = var.aws_region
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      aws s3api create-bucket --bucket ${local.bucket_name} --region ${var.aws_region}
      aws s3api put-public-access-block --bucket ${local.bucket_name} \
        --public-access-block-configuration "BlockPublicAcls=false,IgnorePublicAcls=false,BlockPublicPolicy=false,RestrictPublicBuckets=false"
      aws s3 website s3://${local.bucket_name}/ --index-document index.html --error-document index.html
      aws s3api put-bucket-policy --bucket ${local.bucket_name} --policy file://${local_file.bucket_policy.filename}
    EOT
  }

  # Al hacer "terraform destroy", borra el bucket (y su contenido) por CLI,
  # igual que "aws s3 rb --force" en etapa_4_cleanup.sh.
  provisioner "local-exec" {
    when    = destroy
    command = "aws s3 rb s3://${self.triggers.bucket_name} --force || true"
  }

  depends_on = [local_file.bucket_policy]
}
