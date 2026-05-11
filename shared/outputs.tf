# Outputs consumidos por los stacks de cada bot via terraform_remote_state.
output "region" { value = var.region }
output "vpc_id" { value = aws_vpc.main.id }
output "public_subnet_ids" { value = aws_subnet.public[*].id }
output "ecs_cluster_arn" { value = aws_ecs_cluster.main.arn }
output "ecs_cluster_name" { value = aws_ecs_cluster.main.name }
output "ecs_security_group_id" { value = aws_security_group.ecs_tasks.id }
output "task_execution_role_arn" { value = aws_iam_role.ecs_task_execution.arn }
output "task_role_arn" { value = aws_iam_role.ecs_task.arn }

# Los IAM users para CI/CD (botwb-jenkins, botwb-iac-terraform) NO se manejan
# desde terraform — viven fuera del state para evitar que un `terraform destroy`
# del shared rompa el ciclo (Jenkins quedaría sin permisos para reaplicar).
# Se crean con scripts/bootstrap-iam.sh.
