resource "aws_cognito_user_pool" "users" {
  name = "${local.name}-users"

  password_policy {
    minimum_length = 12
  }
}

resource "aws_cognito_user_pool_client" "api" {
  name            = "${local.name}-api-client"
  user_pool_id    = aws_cognito_user_pool.users.id
  generate_secret = false

  explicit_auth_flows = [
    "ALLOW_ADMIN_USER_PASSWORD_AUTH", # only callable with IAM credentials (admin-initiate-auth)
    "ALLOW_REFRESH_TOKEN_AUTH",
  ]
}
