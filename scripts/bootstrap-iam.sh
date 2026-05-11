#!/usr/bin/env bash
# Bootstrap de IAM users para CI/CD (out-of-band, NO manejado por terraform).
#
# Razonamiento: estos users son el "operador" del terraform. Si terraform los
# manejara, un `terraform destroy` los borraría junto con sus access keys,
# rompiendo el ciclo (Jenkins queda sin permisos para reaplicar). Por eso
# viven fuera del state.
#
# Idempotente: si el user ya existe, no falla. Si ya tiene una access key
# activa, no crea otra (AWS limita a 2 por user). En ese caso, las creds
# son las que ya tenés en Jenkins.
#
# Pre-requisitos:
#   - AWS creds locales admin (ej. user falcon-cli)
#   - awscli + jq
#
# Uso:
#   cd IaC/
#   ./scripts/bootstrap-iam.sh

set -euo pipefail

REGION=us-east-1

# ===========================================================================
# botwb-jenkins (pipeline botwb-deploy, restringido a ECR + ECS + PassRole)
# ===========================================================================
JENKINS_USER=botwb-jenkins
JENKINS_POLICY_NAME=botwb-jenkins-policy

JENKINS_POLICY_JSON=$(cat <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ECRAuth",
      "Effect": "Allow",
      "Action": ["ecr:GetAuthorizationToken"],
      "Resource": "*"
    },
    {
      "Sid": "ECRPushPull",
      "Effect": "Allow",
      "Action": [
        "ecr:BatchCheckLayerAvailability",
        "ecr:GetDownloadUrlForLayer",
        "ecr:BatchGetImage",
        "ecr:InitiateLayerUpload",
        "ecr:UploadLayerPart",
        "ecr:CompleteLayerUpload",
        "ecr:PutImage",
        "ecr:DescribeRepositories",
        "ecr:DescribeImages",
        "ecr:ListImages"
      ],
      "Resource": "arn:aws:ecr:us-east-1:*:repository/*"
    },
    {
      "Sid": "ECSDeploy",
      "Effect": "Allow",
      "Action": [
        "ecs:DescribeServices",
        "ecs:DescribeTaskDefinition",
        "ecs:DescribeTasks",
        "ecs:ListTasks",
        "ecs:ListServices",
        "ecs:RegisterTaskDefinition",
        "ecs:UpdateService"
      ],
      "Resource": "*"
    },
    {
      "Sid": "PassRoleECS",
      "Effect": "Allow",
      "Action": "iam:PassRole",
      "Resource": [
        "arn:aws:iam::*:role/botwb-ecs-task-execution",
        "arn:aws:iam::*:role/botwb-ecs-task"
      ]
    },
    {
      "Sid": "STSIdentity",
      "Effect": "Allow",
      "Action": "sts:GetCallerIdentity",
      "Resource": "*"
    }
  ]
}
EOF
)

# ===========================================================================
# botwb-iac-terraform (pipeline iac-apply, admin)
# ===========================================================================
TERRAFORM_USER=botwb-iac-terraform
TERRAFORM_POLICY_ARN="arn:aws:iam::aws:policy/AdministratorAccess"

# ===========================================================================
# Helpers
# ===========================================================================
ensure_user() {
  local user="$1"
  if aws iam get-user --user-name "$user" >/dev/null 2>&1; then
    echo "  = user $user ya existe"
  else
    echo "  + creando user $user"
    aws iam create-user --user-name "$user" >/dev/null
  fi
}

ensure_inline_policy() {
  local user="$1" policy_name="$2" policy_json="$3"
  echo "  + put-user-policy $policy_name → $user"
  aws iam put-user-policy --user-name "$user" --policy-name "$policy_name" \
    --policy-document "$policy_json"
}

ensure_attached_policy() {
  local user="$1" policy_arn="$2"
  if aws iam list-attached-user-policies --user-name "$user" \
      --query "AttachedPolicies[?PolicyArn=='$policy_arn']" --output text | grep -q .; then
    echo "  = policy $policy_arn ya attached a $user"
  else
    echo "  + attach-user-policy $policy_arn → $user"
    aws iam attach-user-policy --user-name "$user" --policy-arn "$policy_arn"
  fi
}

ensure_access_key() {
  local user="$1"
  local count=$(aws iam list-access-keys --user-name "$user" \
    --query 'length(AccessKeyMetadata[?Status==`Active`])' --output text)
  if [[ "$count" -gt 0 ]]; then
    echo "  = user $user ya tiene $count access key(s) active. NO se crea nueva."
    echo "    Si necesitás recuperar el secret, hay que rotar: eliminar la vieja y correr esto de nuevo."
    return
  fi
  echo "  + creando access key para $user"
  local creds=$(aws iam create-access-key --user-name "$user" --query 'AccessKey.[AccessKeyId,SecretAccessKey]' --output text)
  local key_id=$(echo "$creds" | cut -f1)
  local secret=$(echo "$creds" | cut -f2)
  echo "  ┌──────────────────────────────────────────────────────────"
  echo "  │ ACCESS KEY GENERADA — guardala YA en Jenkins Credentials:"
  echo "  │   user:     $user"
  echo "  │   key id:   $key_id"
  echo "  │   secret:   $secret"
  echo "  │ (el secret no se puede recuperar después)"
  echo "  └──────────────────────────────────────────────────────────"
}

# ===========================================================================
# Run
# ===========================================================================
echo "=== Bootstrap IAM users para CI/CD ==="
echo ""
echo "→ $JENKINS_USER (pipeline botwb-deploy)"
ensure_user "$JENKINS_USER"
ensure_inline_policy "$JENKINS_USER" "$JENKINS_POLICY_NAME" "$JENKINS_POLICY_JSON"
ensure_access_key "$JENKINS_USER"

echo ""
echo "→ $TERRAFORM_USER (pipeline iac-apply, admin)"
ensure_user "$TERRAFORM_USER"
ensure_attached_policy "$TERRAFORM_USER" "$TERRAFORM_POLICY_ARN"
ensure_access_key "$TERRAFORM_USER"

echo ""
echo "=== Done ==="
echo ""
echo "Si se imprimieron access keys arriba, cargalas en Jenkins:"
echo "  - Manage Jenkins → Credentials → System → Global → Add Credentials"
echo "  - Kind: Username with password"
echo "  - aws-jenkins   → username=<key id de $JENKINS_USER>,   password=<secret>"
echo "  - aws-terraform → username=<key id de $TERRAFORM_USER>, password=<secret>"
