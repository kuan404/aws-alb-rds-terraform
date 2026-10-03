output "vpc_id" {
  value = aws_vpc.main.id
}

output "public_subnet_ids" {
  value = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  value = aws_subnet.private[*].id
}

output "nat_gateway_id" {
  value = aws_nat_gateway.main.id
}

output "alb_dns_name" {
  value = aws_lb.main.dns_name # ALB DNS name for public access
}

output "target_group_arn" {
  value = aws_lb_target_group.app.arn
}

output "ec2_instance_id" {
  value = aws_instance.app.id
}

output "ec2_private_ip" {
  value = aws_instance.app.private_ip
}

output "rds_endpoint" {
  value = aws_db_instance.main.endpoint
}
