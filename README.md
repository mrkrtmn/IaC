# IaC — Infraestructura AWS (mrkrtmn)

Terraform para la infra que corre los bots WhatsApp en AWS (ECS Fargate + Cloudflare Tunnel sidecar + SSM Parameter Store SecureString).

## Documentación

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — diagrama de runtime, componentes, decisiones de diseño
- [docs/RUNBOOK.md](docs/RUNBOOK.md) — operaciones diarias (deploy, rotar secrets, troubleshooting)
- [docs/SECRETS.md](docs/SECRETS.md) — gestión de los 3 tipos de secrets (SSM, Jenkins, Meta system user)

## Estructura

```
IaC/
├── Jenkinsfile             # pipeline parametrizado (plan/apply/destroy por stack)
├── modules/
│   └── bot-service/        # módulo reusable: ECR + SSM + Task Def + Service
├── shared/                 # infra compartida: VPC, ECS cluster, IAM roles
│   ├── *.tf
│   ├── backend.tf          # state: s3://mrkrtmn-iac-tfstate/shared/terraform.tfstate
│   └── terraform.tfvars
├── bots/
│   └── faitpro-bot/        # un directorio por bot, cada uno con su propio state y tfvars
│       ├── main.tf         # invoca module bot-service + remote_state shared
│       ├── backend.tf      # state: s3://mrkrtmn-iac-tfstate/bots/faitpro-bot/terraform.tfstate
│       └── terraform.tfvars
├── scripts/
│   ├── bootstrap-iam.sh                  # crea los IAM users de CI/CD (out-of-band)
│   └── migrate-state-from-pipelines.sh   # migración del state viejo (one-shot, ya hecha)
├── .jenkins/
│   └── iac-apply-config.xml              # backup del config del job Jenkins
└── docs/
    ├── ARCHITECTURE.md
    ├── RUNBOOK.md
    └── SECRETS.md
```

## Estado actual

- ✅ Backend S3 + DynamoDB
- ✅ IAM users `botwb-jenkins` y `botwb-iac-terraform` (creados via `bootstrap-iam.sh`)
- ✅ Stack `shared/` aplicado (VPC + ECS cluster + IAM roles)
- ✅ Stack `bots/faitpro-bot/` aplicado (ECR + 15 SSM + task def + service)
- ✅ Job Jenkins `iac-apply` creado y testeado end-to-end (destroy → apply funcionan)
- ✅ Job Jenkins `botwb-deploy` (preexistente, sin cambios)
- ✅ Bot deployado, recibiendo y respondiendo mensajes WhatsApp
- ✅ Token Meta System User permanente (no expira)
- ⏳ Number `+591 67045646` pendiente: bloqueado por business verification de Meta

## Backend remoto

- **S3 bucket**: `mrkrtmn-iac-tfstate` (us-east-1, versioning + SSE-S3, no public access)
- **DynamoDB table**: `tf-locks` (LockID partition key, PAY_PER_REQUEST)
- Cada stack escribe a una key distinta dentro del bucket.

El bootstrap del bucket+tabla está fuera de terraform (creado con awscli). Si se pierde la cuenta, recrearlo con los comandos en la sección "Bootstrap desde cero".

## Bootstrap desde cero

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

# 2. Bootstrap IAM users (out-of-band, una sola vez)
./scripts/bootstrap-iam.sh
# Imprime las access keys de botwb-jenkins y botwb-iac-terraform.
# Cargalas en Jenkins → Credentials:
#   - aws-jenkins   (username = access key id, password = secret) → user botwb-jenkins
#   - aws-terraform (idem)                                        → user botwb-iac-terraform

# 3. Crear los jobs en Jenkins
#   - iac-apply: Pipeline from SCM → mrkrtmn/IaC.git → Jenkinsfile (config backup en .jenkins/iac-apply-config.xml)
#   - botwb-deploy: ya existe en mrkrtmn/pipelines.git → botwb.jenkinsfile

# 4. Configurar Terraform tool en Jenkins
#   Manage Jenkins → Tools → Terraform installations → Add → Name: "terraform"
#   Install automatically → Install from Releases.hashicorp.com → version 1.15.2 linux (amd64)

# 5. Apply shared (Jenkins iac-apply STACK=shared ACTION=apply)
# 6. Apply bot (Jenkins iac-apply STACK=bots/faitpro-bot ACTION=apply)
# 7. Setear los 15 SSM secrets (manualmente o desde un .env de backup)
# 8. Crear tunnel en Cloudflare, setear cloudflare-tunnel-token en SSM
# 9. botwb-deploy PROJECT=faitpro-bot
# 10. aws ecs update-service --desired-count 1
```

### ¿Por qué los IAM users no están en terraform?

Si terraform los manejara, un `terraform destroy` los borraría — incluyendo el user `botwb-iac-terraform` que es **el que Jenkins usa para correr terraform**. Es el clásico "huevo-gallina": destruirías al operador en medio de la operación, y Jenkins quedaría sin permisos para volver a aplicar.

Por eso los IAM users (y solo los IAM users de CI/CD) viven fuera del state, gestionados por `scripts/bootstrap-iam.sh`. Es el mismo patrón por el cual el bucket S3 + DynamoDB del backend también están fuera de terraform.

## Pipeline Jenkins (`iac-apply`)

Parámetros:
- `STACK`: choice (`shared`, `bots/faitpro-bot`, …) — la carpeta a aplicar
- `ACTION`: choice (`plan`, `apply`, `destroy`)
- `AUTO_APPROVE`: bool (default false) — saltea el approval manual

Flujo:
1. Validar que existe el stack
2. `terraform init` (con backend S3) usando la tool `terraform` configurada en Jenkins
3. `terraform validate` + `plan` (o `plan -destroy`) → guarda `tfplan` + `plan.txt` (archivado como artifact)
4. Si action ≠ plan y AUTO_APPROVE=false → **input manual** mostrando las últimas 80 líneas del plan
5. `terraform apply tfplan`

Credencial Jenkins requerida: `aws-terraform` (tipo "Username with password", username = AWS_ACCESS_KEY_ID, password = AWS_SECRET_ACCESS_KEY).

## Agregar un bot nuevo

Ver [docs/ARCHITECTURE.md → Multi-tenancy](docs/ARCHITECTURE.md#multi-tenancy) para el paso a paso.

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

## Repos relacionados

- **`mrkrtmn/IaC`** (este repo) — infraestructura AWS via terraform
- **`mrkrtmn/pipelines`** — Jenkinsfile de deploy de bots (`botwb.jenkinsfile`) + `projects.groovy`
- **`mrkrtmn/FAITPro-bot`** — código del bot (Python + FastAPI)
