# Outputs consumidos por los stacks de cada bot via terraform_remote_state.
output "region" { value = var.region }
output "vpc_id" { value = aws_vpc.main.id }
output "public_subnet_ids" { value = aws_subnet.public[*].id }
output "ecs_cluster_arn" { value = aws_ecs_cluster.main.arn }
output "ecs_cluster_name" { value = aws_ecs_cluster.main.name }
output "ecs_security_group_id" { value = aws_security_group.ecs_tasks.id }
output "task_execution_role_arn" { value = aws_iam_role.ecs_task_execution.arn }
output "task_role_arn" { value = aws_iam_role.ecs_task.arn }

# Credenciales para Jenkins (sensibles).
# Obtener con: terraform output -raw <name>
# Cargar en Jenkins → Credentials → AWS Credentials.

output "jenkins_deploy_access_key_id" {
  description = "Access key del IAM user botwb-jenkins (pipeline botwb-deploy, restringido a ECR+ECS)"
  value       = aws_iam_access_key.jenkins.id
  sensitive   = true
}

output "jenkins_deploy_secret_access_key" {
  value     = aws_iam_access_key.jenkins.secret
  sensitive = true
}

output "terraform_access_key_id" {
  description = "Access key del IAM user botwb-iac-terraform (pipeline iac-apply, admin)"
  value       = aws_iam_access_key.terraform.id
  sensitive   = true
}

output "terraform_secret_access_key" {
  value     = aws_iam_access_key.terraform.secret
  sensitive = true
}
