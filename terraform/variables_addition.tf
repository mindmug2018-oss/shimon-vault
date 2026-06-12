# terraform/variables_addition.tf
# New variables added during Week 3 fixes.
# Keep separate so the original variables.tf is not overwritten.

variable "deploy_green" {
  description = "Set to true during a blue/green deployment to create the green instance. Default false = no green EC2 running (zero cost at rest)."
  type        = bool
  default     = false
}
