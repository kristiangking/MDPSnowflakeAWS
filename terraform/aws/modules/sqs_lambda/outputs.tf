output "queue_arn" {
  description = "ARN of the inventory events SQS queue — used by producers sending events"
  value       = aws_sqs_queue.main.arn
}

output "queue_url" {
  description = "URL of the inventory events SQS queue"
  value       = aws_sqs_queue.main.url
}

output "dlq_arn" {
  description = "ARN of the inventory events dead-letter queue"
  value       = aws_sqs_queue.dlq.arn
}

output "lambda_arn" {
  description = "ARN of the inventory events Lambda consumer"
  value       = aws_lambda_function.consumer.arn
}
