output "public_ip" {
  value = aws_instance.datahub.public_ip
}

output "instance_id" {
  value = aws_instance.datahub.id
}

output "datahub_url" {
  value = "http://${aws_instance.datahub.public_ip}:9002"
}

output "gms_url" {
  description = "DataHub GMS REST API URL (private IP, port 8080) for intra-VPC use"
  value       = "http://${aws_instance.datahub.private_ip}:8080"
}
