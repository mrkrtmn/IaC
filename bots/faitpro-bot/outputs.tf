output "ecr_repository_url"           { value = module.this.ecr_repository_url }
output "ecs_service_name"             { value = module.this.ecs_service_name }
output "task_family"                  { value = module.this.task_family }
output "log_group_name"               { value = module.this.log_group_name }
output "app_secret_names"             { value = module.this.app_secret_names }
output "cloudflare_tunnel_secret_name" { value = module.this.cloudflare_tunnel_secret_name }
