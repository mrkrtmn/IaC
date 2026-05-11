#!/usr/bin/env bash
# Migra el state actual de ../pipelines/terraform (local) al nuevo backend S3 dividido en
# shared/ + bots/faitpro-bot/.
#
# Estrategia: terraform import de cada recurso AWS existente en el nuevo state.
# NO destruye nada. Después del script, `terraform plan` debería ser no-op (modulo tags).
#
# Pre-requisitos:
#   - AWS creds locales configuradas (admin)
#   - terraform CLI
#   - jq
#   - Bootstrap S3 + DynamoDB ya hecho (aws s3api create-bucket, etc.)
#
# Uso:
#   cd IaC/
#   ./scripts/migrate-state-from-pipelines.sh

set -euo pipefail

IAC_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OLD_TF="${IAC_ROOT}/../pipelines/terraform"
REGION=us-east-1

if [[ ! -f "${OLD_TF}/terraform.tfstate" ]]; then
  echo "✗ No se encontró ${OLD_TF}/terraform.tfstate"
  exit 1
fi

echo "=== Pulling state actual ==="
OLD_STATE=$(cd "${OLD_TF}" && terraform state pull)
echo "$OLD_STATE" | jq '.resources | length' | xargs -I {} echo "Recursos en state viejo: {}"

# ---------------------------------------------------------------------------
# 1. Migración SHARED (VPC, ECS cluster, IAM, SG, subnets, etc.)
# ---------------------------------------------------------------------------
echo
echo "=== shared/ ==="
cd "${IAC_ROOT}/shared"

terraform init -input=false

# Mapeo recurso → ID/ARN/nombre que terraform import necesita.
# Los IDs los sacamos del state viejo.
get_id() {
  local addr="$1"
  echo "$OLD_STATE" | jq -r --arg a "$addr" \
    '.resources[] | select((.module // "") + .type + "." + .name == $a) | .instances[0].attributes.id // .instances[0].attributes.arn // empty'
}
get_attr() {
  local addr="$1" attr="$2"
  echo "$OLD_STATE" | jq -r --arg a "$addr" --arg k "$attr" \
    '.resources[] | select((.module // "") + .type + "." + .name == $a) | .instances[0].attributes[$k] // empty'
}

# Lista de recursos shared a importar: addr_old → addr_new (same name acá)
import_shared() {
  local resource="$1" id="$2"
  if [[ -z "$id" ]]; then
    echo "  ! skip $resource (no ID)"
    return
  fi
  if terraform state show "$resource" >/dev/null 2>&1; then
    echo "  = $resource ya importado"
    return
  fi
  echo "  + import $resource ($id)"
  terraform import -input=false "$resource" "$id"
}

import_shared 'aws_vpc.main'                              "$(get_id aws_vpc.main)"
import_shared 'aws_internet_gateway.main'                 "$(get_id aws_internet_gateway.main)"
import_shared 'aws_route_table.public'                    "$(get_id aws_route_table.public)"
import_shared 'aws_security_group.ecs_tasks'              "$(get_id aws_security_group.ecs_tasks)"
import_shared 'aws_ecs_cluster.main'                      "$(get_attr aws_ecs_cluster.main name)"
import_shared 'aws_ecs_cluster_capacity_providers.main'   "$(get_attr aws_ecs_cluster.main name)"
import_shared 'aws_iam_role.ecs_task_execution'           "$(get_attr aws_iam_role.ecs_task_execution name)"
import_shared 'aws_iam_role.ecs_task'                     "$(get_attr aws_iam_role.ecs_task name)"
import_shared 'aws_iam_user.jenkins'                      "$(get_attr aws_iam_user.jenkins name)"

# Subnets y route table associations vienen en count[0..1]
for i in 0 1; do
  import_shared "aws_subnet.public[$i]" "$(echo "$OLD_STATE" | jq -r --argjson i "$i" '.resources[] | select(.type=="aws_subnet" and .name=="public") | .instances[$i].attributes.id // empty')"
  import_shared "aws_route_table_association.public[$i]" "$(echo "$OLD_STATE" | jq -r --argjson i "$i" '.resources[] | select(.type=="aws_route_table_association" and .name=="public") | .instances[$i].attributes.id // empty')"
done

# Policies attached separately
import_shared 'aws_iam_role_policy_attachment.ecs_task_execution_managed' \
  "$(get_attr aws_iam_role.ecs_task_execution name)/arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
import_shared 'aws_iam_role_policy.ecs_task_execution_secrets' \
  "$(get_attr aws_iam_role.ecs_task_execution name):botwb-ecs-task-execution-secrets"
import_shared 'aws_iam_user_policy.jenkins' \
  "$(get_attr aws_iam_user.jenkins name):botwb-jenkins-policy"
# aws_iam_access_key no se puede importar (es secreto), terraform lo va a recrear → guardar el secret_key viejo si lo necesitás
echo "  ! aws_iam_access_key.jenkins NO se puede importar (secret no expuesto). Terraform va a generar uno nuevo."
echo "  ! aws_iam_access_key.terraform es NUEVO (no existe en el state viejo)."

echo
echo "=== shared/ plan ==="
terraform plan -input=false

# ---------------------------------------------------------------------------
# 2. Migración BOT (faitpro-bot)
# ---------------------------------------------------------------------------
echo
echo "=== bots/faitpro-bot/ ==="
cd "${IAC_ROOT}/bots/faitpro-bot"

terraform init -input=false

import_bot() {
  local resource="$1" id="$2"
  if [[ -z "$id" ]]; then echo "  ! skip $resource (no ID)"; return; fi
  if terraform state show "$resource" >/dev/null 2>&1; then echo "  = $resource ya importado"; return; fi
  echo "  + import $resource ($id)"
  terraform import -input=false "$resource" "$id"
}

# ECR repo
ECR_NAME=$(echo "$OLD_STATE" | jq -r '.resources[] | select(.type=="aws_ecr_repository" and .module=="module.faitpro_bot") | .instances[0].attributes.name')
import_bot 'module.this.aws_ecr_repository.this' "$ECR_NAME"
import_bot 'module.this.aws_ecr_lifecycle_policy.this' "$ECR_NAME"
import_bot 'module.this.aws_cloudwatch_log_group.this' "/ecs/faitpro-bot"

# SSM params (uno por cada secret_key + el cloudflare tunnel token)
for KEY in OPENAI_API_KEY META_PHONE_NUMBER_ID META_ACCESS_TOKEN META_APP_SECRET META_VERIFY_TOKEN \
           TELEGRAM_BOT_TOKEN TELEGRAM_CHAT_ID \
           AZURE_TENANT_ID AZURE_CLIENT_ID AZURE_CLIENT_SECRET CALENDAR_EMAIL \
           MAILGUN_API_KEY MAILGUN_DOMAIN MAILGUN_FROM_EMAIL; do
  import_bot "module.this.aws_ssm_parameter.app[\"${KEY}\"]" "/faitpro-bot/${KEY}"
done
import_bot 'module.this.aws_ssm_parameter.cloudflare_tunnel_token' '/faitpro-bot/cloudflare-tunnel-token'

# ECS task definition: import por familia (terraform va a leer la última revisión)
import_bot 'module.this.aws_ecs_task_definition.this' 'faitpro-bot'

# ECS service: import por cluster/service-name
import_bot 'module.this.aws_ecs_service.this' 'botwb-cluster/faitpro-bot'

echo
echo "=== bots/faitpro-bot/ plan ==="
terraform plan -input=false

echo
echo "=== Migración completa ==="
echo "Revisá los plans arriba. Deberían ser no-op (o cambios menores en tags por default_tags)."
echo "Si todo se ve bien, podés borrar ${OLD_TF}/terraform.tfstate* y dejar pipelines/ solo con el Jenkinsfile de deploy."
