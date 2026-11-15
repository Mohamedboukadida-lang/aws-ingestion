resource "aws_dynamodb_table" "events" {
  name         = "${local.name}-events"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "pk"
  range_key    = "sk"

  attribute {
    name = "pk"
    type = "S"
  }

  attribute {
    name = "sk"
    type = "S"
  }

  attribute {
    name = "day"
    type = "S"
  }

  attribute {
    name = "recorded_at"
    type = "S"
  }

  # Lets the daily aggregation read one day of events with a Query, not a table Scan.
  global_secondary_index {
    name            = "by_day"
    hash_key        = "day"
    range_key       = "recorded_at"
    projection_type = "ALL"
  }

  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled = true
  }
}
