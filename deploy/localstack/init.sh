#!/bin/bash
# Runs when LocalStack is ready. Creates the topic, Email's queue, and the subscription.
set -euo pipefail

TOPIC_ARN=$(awslocal sns create-topic --name order-events --query TopicArn --output text)
QUEUE_URL=$(awslocal sqs create-queue --queue-name email-order-events --query QueueUrl --output text)
QUEUE_ARN=$(awslocal sqs get-queue-attributes --queue-url "$QUEUE_URL" \
  --attribute-names QueueArn --query Attributes.QueueArn --output text)

# RawMessageDelivery: the SQS body is exactly what Order published, not wrapped in an SNS envelope.
awslocal sns subscribe --topic-arn "$TOPIC_ARN" --protocol sqs \
  --notification-endpoint "$QUEUE_ARN" --attributes RawMessageDelivery=true

echo "ticket-drop: SNS/SQS ready"
