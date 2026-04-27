output "public_ip" {
  value = aws_instance.airflow.public_ip
}

output "instance_id" {
  value = aws_instance.airflow.id
}