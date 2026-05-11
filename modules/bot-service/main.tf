# Repositorio ECR del proyecto. Jenkins pushea acá.
# force_delete=true permite que `terraform destroy` borre el repo aunque tenga imágenes.
resource "aws_ecr_repository" "this" {
  name                 = var.project_name
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }
}

# Mantener solo las últimas 10 imágenes para no acumular costos de storage.
resource "aws_ecr_lifecycle_policy" "this" {
  repository = aws_ecr_repository.this.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep last 10 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 10
      }
      action = { type = "expire" }
    }]
  })
}

# Log group para los containers de este bot (bot + cloudflared sidecar).
resource "aws_cloudwatch_log_group" "this" {
  name              = "/ecs/${var.project_name}"
  retention_in_days = 14
}

# --- SSM Parameter Store SecureString: un parameter por cada key de var.secret_keys ---
# Terraform crea el parameter con valor placeholder; el VALOR real lo setea el operador con:
#   aws ssm put-parameter --name /<project>/<KEY> --value "..." --type SecureString --overwrite
# `ignore_changes = [value]` evita que terraform revierta el valor real seteado por CLI.
# Encripta con la KMS key default de SSM (alias/aws/ssm), gratis.

resource "aws_ssm_parameter" "app" {
  for_each    = toset(var.secret_keys)
  name        = "/${var.project_name}/${each.value}"
  description = "Secret '${each.value}' para ${var.project_name}"
  type        = "SecureString"
  value       = "PLACEHOLDER_REPLACE_ME"

  lifecycle {
    ignore_changes = [value]
  }
}

# Parameter separado para el token del Cloudflare Tunnel del sidecar.
resource "aws_ssm_parameter" "cloudflare_tunnel_token" {
  name        = "/${var.project_name}/cloudflare-tunnel-token"
  description = "Cloudflare Tunnel token (sidecar) para ${var.project_name}"
  type        = "SecureString"
  value       = "PLACEHOLDER_REPLACE_ME"

  lifecycle {
    ignore_changes = [value]
  }
}

# --- Task definition ---
# Dos containers en la misma task (comparten network namespace):
#   - bot:         FastAPI escuchando en var.container_port (default 8000)
#   - cloudflared: tunnel sidecar; conecta saliente a CF, rutea wa.<dominio> -> localhost:<port>
#
# `placeholder_image` solo se usa en la primera revision. Jenkins lee la última revision,
# reemplaza el image y registra una nueva. El service ignora cambios en task_definition
# (ver lifecycle del aws_ecs_service más abajo) para que terraform no pise lo de Jenkins.

locals {
  app_secrets = [
    for k in var.secret_keys : {
      name      = k
      valueFrom = aws_ssm_parameter.app[k].arn
    }
  ]

  app_environment = concat(
    var.tenant_config != "" ? [{ name = "TENANT_CONFIG", value = var.tenant_config }] : [],
    [for k, v in var.extra_env : { name = k, value = v }]
  )
}

resource "aws_ecs_task_definition" "this" {
  family                   = var.project_name
  cpu                      = var.cpu
  memory                   = var.memory
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  execution_role_arn       = var.task_execution_role_arn
  task_role_arn            = var.task_role_arn

  container_definitions = jsonencode([
    {
      name      = "bot"
      image     = var.placeholder_image
      essential = true

      portMappings = [{
        containerPort = var.container_port
        protocol      = "tcp"
      }]

      environment = local.app_environment
      secrets     = local.app_secrets

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.this.name
          awslogs-region        = var.region
          awslogs-stream-prefix = "bot"
        }
      }
    },
    {
      name      = "cloudflared"
      image     = "cloudflare/cloudflared:latest"
      essential = true

      command = ["tunnel", "--no-autoupdate", "run"]

      secrets = [{
        name      = "TUNNEL_TOKEN"
        valueFrom = aws_ssm_parameter.cloudflare_tunnel_token.arn
      }]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.this.name
          awslogs-region        = var.region
          awslogs-stream-prefix = "tunnel"
        }
      }
    }
  ])
}

# --- Service ---
resource "aws_ecs_service" "this" {
  name             = var.project_name
  cluster          = var.cluster_arn
  task_definition  = aws_ecs_task_definition.this.arn
  desired_count    = var.desired_count
  launch_type      = "FARGATE"
  platform_version = "LATEST"

  network_configuration {
    subnets          = var.subnet_ids
    security_groups  = [var.security_group_id]
    assign_public_ip = true
  }

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200

  # Jenkins maneja qué task definition revision corre y el desired_count operacional.
  # Terraform solo crea el service inicialmente.
  lifecycle {
    ignore_changes = [task_definition, desired_count]
  }
}
