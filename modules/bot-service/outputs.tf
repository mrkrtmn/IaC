output "ecr_repository_url" {
  description = "URL del ECR repo (para docker push)"
  value       = aws_ecr_repository.this.repository_url
}

output "ecs_service_name" {
  description = "Nombre del ECS service"
  value       = aws_ecs_service.this.name
}

output "task_family" {
  description = "Nombre de la familia de task definitions"
  value       = aws_ecs_task_definition.this.family
}

output "log_group_name" {
  description = "CloudWatch log group de los containers"
  value       = aws_cloudwatch_log_group.this.name
}

output "secret_arns" {
  description = "ARNs de los SSM parameters de la app, indexados por key"
  value       = { for k, v in aws_ssm_parameter.app : k => v.arn }
}

output "cloudflare_tunnel_secret_arn" {
  description = "ARN del SSM parameter donde va el token del Cloudflare Tunnel"
  value       = aws_ssm_parameter.cloudflare_tunnel_token.arn
}

output "cloudflare_tunnel_secret_name" {
  description = "Nombre del SSM parameter del CF tunnel (para poner el valor con CLI)"
  value       = aws_ssm_parameter.cloudflare_tunnel_token.name
}

output "app_secret_names" {
  description = "Nombres de los SSM parameters de la app (para poner los valores con CLI)"
  value       = [for s in aws_ssm_parameter.app : s.name]
}
