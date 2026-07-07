# Public Application Load Balancer
resource "aws_lb" "external" {
  name               = "monitoring-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.public[*].id

  tags = {
    Name = "monitoring-alb"
  }
}

# Target Group for Grafana (Port 3000)
resource "aws_lb_target_group" "grafana" {
  name     = "monitoring-tg-grafana"
  port     = 3000
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id

  health_check {
    path                = "/api/health"
    port                = "3000"
    protocol            = "HTTP"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 3
    unhealthy_threshold = 3
  }

  stickiness {
    type            = "lb_cookie"
    cookie_duration = 86400
    enabled         = true
  }

  tags = {
    Name = "monitoring-tg-grafana"
  }
}



# ALB Listener for Grafana UI (Port 80)
resource "aws_lb_listener" "grafana_http" {
  load_balancer_arn = aws_lb.external.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.grafana.arn
  }
}


