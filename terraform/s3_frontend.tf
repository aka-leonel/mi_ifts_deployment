resource "random_id" "bucket_suffix" {
  byte_length = 4
}

resource "aws_s3_bucket" "frontend" {
  bucket = "${var.tag_name}-frontend-bucket-${random_id.bucket_suffix.hex}"

  # Permite que 'terraform destroy' borre el bucket aunque tenga objetos adentro,
  # evitando el paso manual de "aws s3 rb --force" del script original
  force_destroy = true

  # En el provider 3.74.0 (ver provider.tf) la config del sitio web es un bloque
  # inline del propio bucket, no un recurso aparte (aws_s3_bucket_website_configuration
  # recién existe desde la v4 del provider).
  website {
    index_document = "index.html"
    error_document = "index.html"
  }

  tags = {
    Name = "${var.tag_name}-frontend-bucket"
  }
}

resource "aws_s3_bucket_public_access_block" "frontend" {
  bucket = aws_s3_bucket.frontend.id

  block_public_acls       = false
  ignore_public_acls      = false
  block_public_policy     = false
  restrict_public_buckets = false
}

resource "aws_s3_bucket_policy" "frontend" {
  bucket = aws_s3_bucket.frontend.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "PublicReadGetObject"
        Effect    = "Allow"
        Principal = "*"
        Action    = "s3:GetObject"
        Resource  = "${aws_s3_bucket.frontend.arn}/*"
      }
    ]
  })

  depends_on = [aws_s3_bucket_public_access_block.frontend]
}
