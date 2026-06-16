# terraform/alb_test_listener_green.tf
#
# WHY THIS EXISTS:
#   The ALB only runs health checks on a target group that is referenced by a
#   listener. The production listener (alb.tf, port 80) points at blue until the
#   blue/green switch, so the GREEN target group is "unused" and never health-
#   checked — which is why the CD pipeline's "wait for green healthy" step polls
#   "unused" forever and times out.
#
#   This adds a second listener on port 8080 that forwards to the green target
#   group whenever green is deployed. That association makes the ALB health-check
#   green's targets on port 8000 (the target group's traffic-port) BEFORE the
#   production switch — so CD can confirm green is healthy, then switch port 80.
#
#   No security-group change is needed: ALB health checks hit the target port
#   (8000, already open to the ALB), not this listener's external port (8080).
#   Gated on var.deploy_green so it disappears outside a deployment.

resource "aws_lb_listener" "green_test" {
  count             = var.deploy_green ? 1 : 0
  load_balancer_arn = aws_lb.main.arn
  port              = 8080
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.green.arn
  }

  depends_on = [
    aws_lb_target_group.green,
    aws_lb_target_group_attachment.green,
  ]
}
