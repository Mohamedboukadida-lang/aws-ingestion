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
    "ALLOW_USER_PASSWORD_AUTH", # for curl testing only; remove on day 8
    "ALLOW_REFRESH_TOKEN_AUTH",
  ]
}
