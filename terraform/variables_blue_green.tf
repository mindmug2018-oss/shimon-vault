# terraform/variables_blue_green.tf
#
# Controls which color is "live". The ALB listener (alb.tf) forwards to the
# target group named by this variable. Because Terraform owns the choice, the
# blue/green switch survives `terraform apply` instead of drifting back — which
# is what happened with the old imperative `aws elbv2 modify-listener` call.
#
# Lifecycle note: this defaults to "blue". The CD pipeline applies
# active_color=green to switch. Do NOT run a plain `terraform apply` / deploy.sh
# (which uses the default "blue") AFTER a CD deploy in the same session, or it
# will switch traffic back to blue. Normal flow is: deploy.sh at session start
# (blue) → CD mid-session (green) → terraform destroy at session end.

variable "active_color" {
  type        = string
  default     = "blue"
  description = "Which target group the ALB listener serves: \"blue\" or \"green\"."

  validation {
    condition     = contains(["blue", "green"], var.active_color)
    error_message = "active_color must be either \"blue\" or \"green\"."
  }
}
