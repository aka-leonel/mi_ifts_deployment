data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "state"
    values = ["available"]
  }
}

resource "aws_instance" "backend" {
  ami                     = data.aws_ami.ubuntu.id
  instance_type           = var.instance_type
  subnet_id               = aws_subnet.public_1.id
  vpc_security_group_ids  = [aws_security_group.backend.id]
  iam_instance_profile    = var.instance_profile_name

  tags = {
    Name = "${var.tag_name}-backend"
  }
}
