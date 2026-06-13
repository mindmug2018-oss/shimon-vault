# terraform/alb.tf — Application Load Balancer

# ─── ALB needs a second public subnet in a different AZ ──────────────────────
resource "aws_subnet" "public_b" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.4.0/24"
  availability_zone       = "${var.aws_region}c"
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.project_name}-public-subnet-b"
    Tier = "public"
  }
}

# Associate public_b with the public route table
resource "aws_route_table_association" "public_b" {
  subnet_id      = aws_subnet.public_b.id
  route_table_id = aws_route_table.public.id
}

# ─── ALB ──────────────────────────────────────────────────────────────────────
resource "aws_lb" "main" {
  name               = "${var.project_name}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]

  # ALB requires at least 2 subnets in different AZs
  subnets = [
    aws_subnet.public.id,
    aws_subnet.public_b.id,
  ]

  enable_deletion_protection = false

  tags = {
    Name    = "${var.project_name}-alb"
    Project = var.project_name
  }
}

# ─── Target Groups ────────────────────────────────────────────────────────────

resource "aws_lb_target_group" "blue" {
  name     = "${var.project_name}-blue"
  port     = 8000
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id

  health_check {
    enabled             = true
    path                = "/health"
    port                = "traffic-port"
    protocol            = "HTTP"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
    matcher             = "200"
  }

  tags = {
    Name    = "${var.project_name}-blue"
    Project = var.project_name
  }
}

resource "aws_lb_target_group" "green" {
  name     = "${var.project_name}-green"
  port     = 8000
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id

  health_check {
    enabled             = true
    path                = "/health"
    port                = "traffic-port"
    protocol            = "HTTP"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
    matcher             = "200"
  }

  tags = {
    Name    = "${var.project_name}-green"
    Project = var.project_name
  }
}

# ─── HTTP Listener (port 80) ──────────────────────────────────────────────────
# Cloudflare terminates HTTPS before traffic reaches the ALB, so plain HTTP:80
# is all we need internally.
#
# CHANGED for Option 1: the listener now forwards to whichever target group
# var.active_color names (blue by default, green during a deploy). This makes
# the blue/green switch a Terraform-owned, drift-free operation instead of an
# out-of-band `aws elbv2 modify-listener` call that Terraform would later undo.
resource "aws_lb_listener" "app" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = var.active_color == "green" ? aws_lb_target_group.green.arn : aws_lb_target_group.blue.arn
  }

  depends_on = [
    aws_lb_target_group.blue,
    aws_lb_target_group.green,
  ]
}

# ─── Outputs ──────────────────────────────────────────────────────────────────

output "alb_dns_name" {
  description = "ALB DNS name — point your Cloudflare CNAME here"
  value       = aws_lb.main.dns_name
}

output "alb_arn" {
  description = "ALB ARN"
  value       = aws_lb.main.arn
}

output "alb_target_group_blue_arn" {
  description = "Blue target group ARN"
  value       = aws_lb_target_group.blue.arn
}

output "alb_target_group_green_arn" {
  description = "Green target group ARN"
  value       = aws_lb_target_group.green.arn
}

# ─── Register blue EC2 in the blue target group ───────────────────────────────
resource "aws_lb_target_group_attachment" "blue" {
  target_group_arn = aws_lb_target_group.blue.arn
  target_id        = aws_instance.app_blue.id
  port             = 8000
}
