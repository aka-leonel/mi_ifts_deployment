resource "aws_security_group" "backend" {
  name        = "${var.tag_name}-sg-backend"
  description = "SG para miIFTS Backend EC2"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "API backend"
    from_port   = 8000
    to_port     = 8000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.tag_name}-sg-backend"
  }
}

resource "aws_security_group" "rds" {
  name        = "${var.tag_name}-sg-rds"
  description = "SG para miIFTS Database RDS"
  vpc_id      = aws_vpc.main.id

  # Tráfico PostgreSQL exclusivamente desde el SG del backend, igual que en el script original
  ingress {
    description     = "PostgreSQL solo desde el backend"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.backend.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.tag_name}-sg-rds"
  }
}
