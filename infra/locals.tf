locals {
  name       = "${var.project}-${var.env}"
  account_id = data.aws_caller_identity.current.account_id
}
