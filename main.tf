provider "aws" {
  region = "us-east-1"
}

# 1. VPC
resource "aws_vpc" "main" {
  cidr_block = "10.0.0.0/16"
  
  tags = {
    Name = "main-vpc"
  }
}

# 2. Internet Gateway
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "main-igw"
  }
}

# 3. Public Subnets
resource "aws_subnet" "public" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = element(["10.0.1.0/24", "10.0.2.0/24"], count.index)
  availability_zone = element(["us-east-1a", "us-east-1b"], count.index)

  tags = {
    Name = "public-subnet-${count.index + 1}"
  }
}

# 4. Private Subnets
resource "aws_subnet" "private" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = element(["10.0.3.0/24", "10.0.4.0/24"], count.index)
  availability_zone = element(["us-east-1a", "us-east-1b"], count.index)

  tags = {
    Name = "private-subnet-${count.index + 1}"
  }
}

# 5. NAT Gateways
resource "aws_eip" "nat" {
  count = 2

  tags = {
    Name = "nat-eip-${count.index + 1}"
  }
}

resource "aws_nat_gateway" "main" {
  count         = 2
  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = element(aws_subnet.public[*].id, count.index)

  tags = {
    Name = "nat-gateway-${count.index + 1}"
  }
}

# 6. Route Tables
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name = "public-rt"
  }
}

resource "aws_route_table_association" "public" {
  count       = length(aws_subnet.public[*].id)
  subnet_id   = element(aws_subnet.public[*].id, count.index)
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "private-rt"
  }
}

resource "aws_route" "private" {
  count        = length(aws_subnet.private[*].id)
  route_table_id = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id = element(aws_nat_gateway.main[*].id, count.index)
}

resource "aws_route_table_association" "private" {
  count       = length(aws_subnet.private[*].id)
  subnet_id   = element(aws_subnet.private[*].id, count.index)
  route_table_id = aws_route_table.private.id
}

# 7. Security Groups
resource "aws_security_group" "web" {
  vpc_id = aws_vpc.main.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 443
    to_port     = 443
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
    Name = "web-sg"
  }
}

resource "aws_security_group" "db" {
  vpc_id = aws_vpc.main.id

  ingress {
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_security_group.web.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "db-sg"
  }
}

# 8. Load Balancer
resource "aws_lb" "web" {
  name               = "web-lb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.web.id]
  subnets            = aws_subnet.public[*].id

  tags = {
    Name = "web-lb"
  }
}

resource "aws_lb_target_group" "web" {
  name     = "web-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id

  health_check {
    path = "/"
    port = "80"
  }

  tags = {
    Name = "web-tg"
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.web.arn
  port              = "80"
  protocol          = "HTTP"
  
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.web.arn
  }
}

# 9. Auto Scaling Group and Launch Template
resource "aws_launch_template" "web" {
  name          = "web-template"
  image_id      = "ami-08a0d1e16fc3f61ea"
  instance_type = "t2.micro"
  
  key_name = "your-key-name"
  
  network_interfaces {
    associate_public_ip_address = true
    security_groups = [aws_security_group.web.id]
  }

  user_data = <<-EOF
    #!/bin/bash
    sudo yum update -y
    sudo yum install -y httpd
    sudo systemctl start httpd
    sudo systemctl enable httpd
  EOF

  tags = {
    Name = "web-template"
  }
}

resource "aws_autoscaling_group" "web" {
  desired_capacity     = 2
  max_size             = 4
  min_size             = 2
  vpc_zone_identifier  = aws_subnet.public[*].id
  launch_template {
    id      = aws_launch_template.web.id
    version = "$Latest"
  }

  target_group_arns = [aws_lb_target_group.web.arn]

 
}

# 10. RDS (MySQL) Instance
resource "aws_db_instance" "default" {
  allocated_storage    = 20
  storage_type         = "gp2"
  engine               = "mysql"
  engine_version       = "8.0"
  instance_class       = "db.t2.micro"
  username             = "admin"
  password             = "password"
  db_subnet_group_name = aws_db_subnet_group.default.name
  vpc_security_group_ids = [aws_security_group.db.id]

  skip_final_snapshot = true

  tags = {
    Name = "mydb"
  }
}

resource "aws_db_subnet_group" "default" {
  name       = "mydb-subnet-group"
  subnet_ids = aws_subnet.private[*].id

  tags = {
    Name = "mydb-subnet-group"
  }
}

# 11. S3 Bucket
resource "aws_s3_bucket" "website" {
  bucket = "your-unique-bucket-name"

  tags = {
    Name = "website-bucket"
  }
}

# IAM Role for S3 Access
resource "aws_iam_role" "s3_access" {
  name = "s3_access_role"

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

  tags = {
    Name = "s3_access_role"
  }
}

resource "aws_iam_role_policy" "s3_access_policy" {
  name = "s3_access_policy"
  role = aws_iam_role.s3_access.id

  policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "s3:*",
      "Resource": "*"
    }
  ]
}
EOF
}

resource "aws_iam_instance_profile" "s3_access_profile" {
  name = "s3_access_profile"
  role = aws_iam_role.s3_access.name
}
