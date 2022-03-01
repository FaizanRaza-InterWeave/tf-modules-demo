

provider "aws" {
  region  = "us-east-2"
  profile = "cnf"
}

## Networking - Create Public Subnets

resource "aws_vpc" "app" {
  cidr_block = "172.16.0.0/16"

  tags = {
    Name = "Terraform VPC - App"
  }
}

# Declare the data source
data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.app.id

  tags = {
    Name = "app_vpc_igw"
  }
}

resource "aws_subnet" "web" {
  count             = length(data.aws_availability_zones.available.names)
  vpc_id            = aws_vpc.app.id
  cidr_block        = "172.16.${count.index * 10}.0/24"
  availability_zone = data.aws_availability_zones.available.names[count.index]

  tags = {
    Name = "Terraform Subnet - Web -${data.aws_availability_zones.available.zone_ids[count.index]}"
  }
}

resource "aws_route_table" "public_rt" {
  vpc_id = aws_vpc.app.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = {
    Name = "public_rt"
  }
}

resource "aws_route_table_association" "public_rt_asso" {
  count          = length(data.aws_availability_zones.available.names)
  subnet_id      = aws_subnet.web[count.index].id
  route_table_id = aws_route_table.public_rt.id
}

locals {
  http_port    = 80
  any_port     = 0
  any_protocol = "-1"
  tcp_protocol = "tcp"
  all_ips      = ["0.0.0.0/0"]
}


resource "aws_security_group" "web_server8080" {
  name   = "${var.cluster_name}-alb"
  vpc_id = aws_vpc.app.id
  ingress {
    from_port   = var.server_port
    to_port     = var.server_port
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "alb" {
  name   = "app-alb-80"
  vpc_id = aws_vpc.app.id

  # Allow inbound HTTP requests
  ingress {
    from_port   = local.http_port
    to_port     = local.http_port
    protocol    = local.tcp_protocol
    cidr_blocks = local.all_ips
  }
  # Allow all outbound requests
  egress {
    from_port   = local.any_port
    to_port     = local.any_port
    protocol    = local.any_protocol
    cidr_blocks = local.all_ips
  }
}



locals {
  subnets = [for k, v in aws_subnet.web : v.id]
}


data "template_file" "user_data" {
  template = file("${path.module}/user-data.sh")
  vars = {
    server_port = var.server_port
    db_address  = data.terraform_remote_state.db.outputs.address
    db_port     = data.terraform_remote_state.db.outputs.port
  }
}

resource "aws_launch_configuration" "web_servers" {
  image_id        = "ami-0c55b159cbfafe1f0"
  instance_type   = var.instance_type
  security_groups = [aws_security_group.web_server8080.id]
  user_data       = data.template_file.user_data.rendered

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_autoscaling_group" "web_servers" {
  launch_configuration = aws_launch_configuration.web_servers.name
  vpc_zone_identifier  = local.subnets

  target_group_arns = [aws_lb_target_group.app-asg.arn]
  health_check_type = "ELB"



  min_size = var.min_size
  max_size = var.max_size

  tag {
    key                 = "Name"
    value               = "terraform-asg-example"
    propagate_at_launch = true
  }
}


resource "aws_lb" "web_alb" {
  name               = "web-alb-${var.uid}"
  load_balancer_type = "application"
  subnets            = local.subnets
  security_groups    = [aws_security_group.alb.id]
}

resource "aws_lb_target_group" "app-asg" {
  name     = "app-asg-target-group-${var.uid}"
  port     = var.server_port
  protocol = "HTTP"
  vpc_id   = aws_vpc.app.id

  health_check {
    path                = "/"
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 15
    timeout             = 3
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.web_alb.arn
  port              = local.http_port
  protocol          = "HTTP"
  # By default, return a simple 404 page
  default_action {

    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      message_body = "404: page not found"
      status_code  = 404
    }
  }
}

resource "aws_lb_listener_rule" "app-asg" {
  listener_arn = aws_lb_listener.http.arn
  priority     = 100
  condition {
    path_pattern {
      values = ["*"]
    }
  }
  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app-asg.arn
  }
}

