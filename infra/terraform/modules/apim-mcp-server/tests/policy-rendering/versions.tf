# No provider requirement: this fixture only calls templatefile() over a
# local file, so there is nothing to pin beyond the Terraform version itself
# (matches the repo's pin, docs/specs/v1-tracer-bullet.md "Terraform and
# state").

terraform {
  required_version = ">= 1.15.8, < 2.0.0"
}
