output "endpoint_url" {
  description = "HTTPS URL callers POST events to — e.g. https://<id>.execute-api.<region>.amazonaws.com/v1/events"
  value       = "${aws_api_gateway_stage.v1.invoke_url}/events"
}

output "api_key_id" {
  description = "API Gateway API key ID — retrieve the value via: aws apigateway get-api-key --api-key <id> --include-value"
  value       = aws_api_gateway_api_key.default.id
}
