variable "project_name" {
  description = "Nombre del bot (ECR repo, SSM prefix, ECS service)"
  type        = string
}

variable "tenant_config" {
  description = "Path relativo al config YAML del tenant dentro del image (env var TENANT_CONFIG)"
  type        = string
  default     = ""
}

variable "secret_keys" {
  description = "Lista de keys de SSM Parameter Store SecureString a inyectar como env vars"
  type        = list(string)
  default     = []
}

variable "extra_env" {
  description = "Env vars adicionales no sensibles (map name->value)"
  type        = map(string)
  default     = {}
}

variable "cpu" {
  type    = number
  default = 256
}

variable "memory" {
  type    = number
  default = 512
}

variable "desired_count" {
  description = "Cantidad inicial de tasks corriendo (después se maneja con `aws ecs update-service --desired-count N`)"
  type        = number
  default     = 0
}

variable "container_port" {
  type    = number
  default = 8000
}

variable "placeholder_image" {
  description = "Imagen inicial antes del primer deploy de Jenkins"
  type        = string
  default     = "public.ecr.aws/nginx/nginx:alpine"
}
