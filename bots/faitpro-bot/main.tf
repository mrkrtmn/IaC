data "terraform_remote_state" "shared" {
  backend = "s3"
  config = {
    bucket = "mrkrtmn-iac-tfstate"
    key    = "shared/terraform.tfstate"
    region = "us-east-1"
  }
}

module "this" {
  source = "../../modules/bot-service"

  project_name = var.project_name
  region       = data.terraform_remote_state.shared.outputs.region

  cluster_arn             = data.terraform_remote_state.shared.outputs.ecs_cluster_arn
  subnet_ids              = data.terraform_remote_state.shared.outputs.public_subnet_ids
  security_group_id       = data.terraform_remote_state.shared.outputs.ecs_security_group_id
  task_execution_role_arn = data.terraform_remote_state.shared.outputs.task_execution_role_arn
  task_role_arn           = data.terraform_remote_state.shared.outputs.task_role_arn

  tenant_config     = var.tenant_config
  secret_keys       = var.secret_keys
  extra_env         = var.extra_env
  cpu               = var.cpu
  memory            = var.memory
  desired_count     = var.desired_count
  container_port    = var.container_port
  placeholder_image = var.placeholder_image
}
