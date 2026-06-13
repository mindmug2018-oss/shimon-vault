# terraform/green_target_group_attachment.tf
#
# Registers the green EC2 instance into the GREEN target group.
#
# Why this file exists:
#   alb.tf already attaches the BLUE instance to the blue target group
#   (aws_lb_target_group_attachment.blue), but there was no equivalent for
#   green. Without it, the green target group is always empty, so the CD
#   pipeline's "wait for green health" step polls "unknown" forever and
#   times out. This attachment is gated on the same `deploy_green` flag as
#   the green instance, so it only exists during a deployment.

resource "aws_lb_target_group_attachment" "green" {
  count            = var.deploy_green ? 1 : 0
  target_group_arn = aws_lb_target_group.green.arn
  target_id        = aws_instance.app_green[0].id
  port             = 8000
}
