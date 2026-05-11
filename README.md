# IaC — Infraestructura AWS (mrkrtmn)

Terraform para la infra que corre los bots WhatsApp en AWS (ECS Fargate + Cloudflare Tunnel sidecar + SSM Parameter Store SecureString).

## Estructura

```
IaC/
├── Jenkinsfile             # pipeline parametrizado (plan/apply/destroy por stack)
├── modules/
│   └── bot-service/        # módulo reusable: ECR + SSM + Task Def + Service
├── shared/                 # infra compartida: VPC, ECS cluster, IAM (jenkins, task, terraform-admin)
│   ├── *.tf
│   ├── backend.tf          # state: s3://mrkrtmn-iac-tfstate/shared/terraform.tfstate
│   └── terraform.tfvars
├── bots/
│   └── faitpro-bot/        # un directorio por bot, cada uno con su propio state y tfvars
│       ├── main.tf         # invoca module bot-service + remote_state shared
│       ├── backend.tf      # state: s3://mrkrtmn-iac-tfstate/bots/faitpro-bot/terraform.tfstate
│       └── terraform.tfvars
└── scripts/
    └── ...
```

## Backend remoto

- **S3 bucket**: `mrkrtmn-iac-tfstate` (us-east-1, versioning + SSE-S3, no public access)
- **DynamoDB table**: `tf-locks` (LockID partition key, PAY_PER_REQUEST)
- Cada stack escribe a una key distinta dentro del bucket.

El bootstrap del bucket+tabla está fuera de terraform (creado con awscli). Si se pierde la cuenta, recrearlo con los comandos en la sección "Bootstrap" más abajo.

## Orden de deploy

Si arrancás desde cero (cuenta AWS limpia):

```bash
# 1. Bootstrap del backend (una sola vez, con creds admin locales)
aws s3api create-bucket --bucket mrkrtmn-iac-tfstate --region us-east-1
aws s3api put-bucket-versioning --bucket mrkrtmn-iac-tfstate --versioning-configuration Status=Enabled
aws s3api put-bucket-encryption --bucket mrkrtmn-iac-tfstate \
  --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
aws s3api put-public-access-block --bucket mrkrtmn-iac-tfstate \
  --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
aws dynamodb create-table --table-name tf-locks \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST --region us-east-1

# 2. Apply de shared (con creds admin locales — crea VPC, ECS, IAM users)
cd shared
terraform init
terraform apply

# 3. Obtener credenciales para Jenkins
terraform output -raw terraform_access_key_id
terraform output -raw terraform_secret_access_key
terraform output -raw jenkins_deploy_access_key_id
terraform output -raw jenkins_deploy_secret_access_key

# 4. Cargarlas en Jenkins → Credentials:
#    - aws-terraform (para este pipeline IaC)
#    - aws-jenkins   (para el pipeline botwb-deploy del repo pipelines/)

# 5. Apply de cada bot (desde Jenkins ya, parámetro STACK=bots/faitpro-bot, ACTION=apply)
```

## Pipeline Jenkins (`iac-apply`)

Pipeline con parámetros:
- `STACK`: choice (`shared`, `bots/faitpro-bot`, …) — la carpeta a aplicar
- `ACTION`: choice (`plan`, `apply`, `destroy`)
- `AUTO_APPROVE`: bool (default false) — saltea el approval manual

Flujo:
1. `terraform init` (con backend S3)
2. `terraform fmt -check` + `terraform validate`
3. `terraform plan` (o `plan -destroy`) → guarda `tfplan` + `plan.txt` (archivado como artifact)
4. Si action ≠ plan y AUTO_APPROVE=false → **input manual** mostrando las últimas 80 líneas del plan
5. `terraform apply tfplan`

Credencial Jenkins requerida: `aws-terraform` (tipo "Username with password", username = AWS_ACCESS_KEY_ID, password = AWS_SECRET_ACCESS_KEY).

## Setear secrets de un bot

Después del primer `apply` de un bot, los SSM SecureString existen con valor `PLACEHOLDER_REPLACE_ME`. Rellenarlos con:

```bash
for KEY in $(terraform -chdir=bots/faitpro-bot output -json app_secret_names | jq -r '.[]'); do
  KEY=${KEY#/faitpro-bot/}
  read -rsp "Valor de ${KEY}: " VALUE; echo
  aws ssm put-parameter --name "/faitpro-bot/${KEY}" --value "${VALUE}" \
    --type SecureString --overwrite --region us-east-1
done
```

Token del Cloudflare Tunnel (después de crear el tunnel en CF dashboard):
```bash
aws ssm put-parameter --name "/faitpro-bot/cloudflare-tunnel-token" \
  --value "<token>" --type SecureString --overwrite --region us-east-1
```

## Agregar un bot nuevo

```bash
# 1. Crear carpeta bots/<nombre>/ copiando faitpro-bot/
cp -r bots/faitpro-bot bots/sabornacional
cd bots/sabornacional

# 2. Editar backend.tf (cambiar la key del state)
#    bots/sabornacional/terraform.tfstate

# 3. Editar terraform.tfvars (project_name, secret_keys, tenant_config)

# 4. Editar Jenkinsfile en la raíz: agregar "bots/sabornacional" al choice del param STACK

# 5. Commit + push, desde Jenkins correr el pipeline con STACK=bots/sabornacional ACTION=apply
```

## Costo estimado por bot (24/7)

| Recurso | Costo/mes |
|---|---|
| Fargate 0.25 vCPU + 0.5 GB | ~$9 |
| Cloudflared sidecar | incluido en el task |
| IP pública (assign_public_ip) | ~$3.65 |
| ECR (hasta 10 imágenes) | <$0.10 |
| SSM Parameter Store SecureString (~15 params, Standard) | $0 |
| CloudWatch Logs (14 días retention) | ~$0.50 |
| S3 + DynamoDB (state + locks) | <$0.10 (compartido entre todos los stacks) |
| **Total estimado por bot** | **~$13** |

VPC, ECS cluster, IAM users, IGW: $0.
