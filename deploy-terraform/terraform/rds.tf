resource "aws_db_subnet_group" "main" {
  name        = "${var.tag_name}-db-subnet-group"
  description = "Subnet group para miIFTS RDS"
  subnet_ids  = [aws_subnet.public_1.id, aws_subnet.public_2.id]

  tags = {
    Name = "${var.tag_name}-db-subnet-group"
  }
}

resource "aws_db_instance" "main" {
  identifier              = "${var.tag_name}-db"
  engine                  = "postgres"
  engine_version          = var.db_engine_version
  instance_class          = var.db_instance_class
  allocated_storage       = var.db_allocated_storage
  username                = var.db_username
  password                = var.db_password
  db_subnet_group_name    = aws_db_subnet_group.main.name
  vpc_security_group_ids  = [aws_security_group.rds.id]
  publicly_accessible     = false
  multi_az                = false

  # Learner Lab: sin snapshot final para que destroy no quede colgado
  skip_final_snapshot = true
  deletion_protection = false
}
