variable "project_name" {
  description = "Nombre del proyecto (sirve de prefijo para ECR repo, secrets, log group)"
  type        = string
}

variable "region" {
  description = "AWS region (para CloudWatch logs)"
  type        = string
}

variable "cluster_arn" {
  description = "ARN del ECS cluster compartido"
  type        = string
}

variable "subnet_ids" {
  description = "Subnets públicas donde corren las tasks"
  type        = list(string)
}

variable "security_group_id" {
  description = "Security group de las tasks (egress-only)"
  type        = string
}

variable "task_execution_role_arn" {
  description = "Role que ECS asume para pullear de ECR y leer secrets"
  type        = string
}

variable "task_role_arn" {
  description = "Role que asumen los containers (acceso a otros servicios AWS)"
  type        = string
}

variable "cpu" {
  description = "CPU units para Fargate (256 = 0.25 vCPU)"
  type        = number
  default     = 256
}

variable "memory" {
  description = "Memoria en MB"
  type        = number
  default     = 512
}

variable "desired_count" {
  description = "Cantidad de tasks corriendo en el service. Default 0: la infra existe pero no gasta compute hasta que se haga el primer Jenkins deploy y se suba con `aws ecs update-service --desired-count N`. Recordá que el service tiene `ignore_changes = [desired_count]`, así que cambios manuales no son revertidos por terraform."
  type        = number
  default     = 0
}

variable "container_port" {
  description = "Puerto interno donde escucha el bot (FastAPI)"
  type        = number
  default     = 8000
}

variable "tenant_config" {
  description = "Path relativo al config YAML del tenant dentro del image (env var TENANT_CONFIG)"
  type        = string
  default     = ""
}

variable "secret_keys" {
  description = "Lista de keys de SSM Parameter Store (SecureString) a inyectar como env vars (los valores se setean manualmente)"
  type        = list(string)
  default     = []
}

variable "extra_env" {
  description = "Env vars adicionales no sensibles (map name->value)"
  type        = map(string)
  default     = {}
}

variable "placeholder_image" {
  description = "Imagen placeholder antes del primer deploy de Jenkins"
  type        = string
  default     = "public.ecr.aws/nginx/nginx:alpine"
}
