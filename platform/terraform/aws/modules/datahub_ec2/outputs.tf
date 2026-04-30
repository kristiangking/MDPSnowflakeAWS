output "public_ip" {
  value = aws_instance.datahub.public_ip
}

output "instance_id" {
  value = aws_instance.datahub.id
}

output "datahub_url" {
  value = "http://${aws_instance.datahub.public_ip}:9002"
}
