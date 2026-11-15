#!/usr/bin/env bash
# Move messages from the events DLQ back to the main queue (after fixing the cause).
set -euo pipefail
name="${1:-aws-ingestion-dev}"
dlq=$(aws sqs get-queue-attributes --queue-url "$(aws sqs get-queue-url --queue-name "${name}-events-dlq" --query QueueUrl --output text)" --attribute-names QueueArn --query Attributes.QueueArn --output text)
src=$(aws sqs get-queue-attributes --queue-url "$(aws sqs get-queue-url --queue-name "${name}-events" --query QueueUrl --output text)" --attribute-names QueueArn --query Attributes.QueueArn --output text)
aws sqs start-message-move-task --source-arn "$dlq" --destination-arn "$src"
