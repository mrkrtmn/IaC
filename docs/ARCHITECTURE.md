# Arquitectura

Plataforma multi-tenant de bots WhatsApp con IA, desplegada en AWS ECS Fargate con Cloudflare Tunnel sidecar.

## Diagrama de runtime (por bot)

```
                                                ┌─────────────────────────────┐
                                                │       Cloudflare edge        │
                                                │  wa-aws.faitpro.com.bo (HTTPS)│
                                                └──────────────┬──────────────┘
                                                               │ tunnel saliente
                                                               │ (no inbound port)
                                                               ↓
┌──────────────────────────────── ECS Fargate Task ────────────────────────────────┐
│                                                                                  │
│   ┌──────────────────────┐                ┌────────────────────────────────────┐ │
│   │ container: bot       │ ←─ localhost ──│ container: cloudflared             │ │
│   │ FastAPI puerto 8000  │     mismo NS   │ cloudflared tunnel run             │ │
│   │ Python 3.11          │                │ secret: cloudflare-tunnel-token    │ │
│   │ image: ECR           │                │                                    │ │
│   │ env vars:            │                │                                    │ │
│   │   - de SSM (15 vars) │                │                                    │ │
│   │   - TENANT_CONFIG    │                │                                    │ │
│   └──────────────────────┘                └────────────────────────────────────┘ │
│                                                                                  │
│   IAM execution role: lee de SSM + KMS + pull de ECR                             │
│   Network: VPC pública con assign_public_ip (egress-only via SG)                 │
│                                                                                  │
└──────────────────────────────────────────────────────────────────────────────────┘

   Outbound a internet (egress-only):
      ↓ api.openai.com (OpenAI Chat Completions)
      ↓ graph.facebook.com (Meta WhatsApp Cloud API)
      ↓ graph.microsoft.com (Microsoft Graph - calendario)
      ↓ www.googleapis.com (Google Calendar - calendario)
      ↓ api.telegram.org (Telegram - notificaciones)
      ↓ api.mailgun.net (Mailgun - emails invitación)
```

## Flujo de un mensaje entrante

```
1. Usuario manda WhatsApp al test number (+1 555-...)
2. Meta WhatsApp Business API recibe el mensaje
3. Meta hace POST https://wa-aws.faitpro.com.bo/webhook
   (URL configurada en Meta del lado del WABA)
4. Cloudflare edge recibe el POST, lo rutea al tunnel `faitpro-bot-aws`
5. El connector cloudflared (sidecar en ECS) recibe el POST por su conexión saliente
6. cloudflared lo proxea a localhost:8000 (el container bot)
7. FastAPI valida HMAC-SHA256 (X-Hub-Signature-256) usando META_APP_SECRET
8. agent.py llama a OpenAI con el historial de la conversación
9. main.py llama a graph.facebook.com con META_ACCESS_TOKEN para enviar la respuesta
10. Telegram notification (opcional, cuando hay PROSPECTO_LISTO)
```

## Componentes por capa

### Capa de infraestructura (terraform — repo `mrkrtmn/IaC`)

#### Stack `shared/`
- **VPC** `botwb-vpc` (10.20.0.0/16) + IGW + 2 subnets públicas en 2 AZs
- **Security Group** `botwb-ecs-tasks` (egress-only, sin inbound)
- **ECS cluster** `botwb-cluster` (Fargate + Fargate Spot)
- **IAM roles** (de aplicación, no de CI/CD):
  - `botwb-ecs-task-execution` — ECS lo usa para pull de ECR y leer SSM
  - `botwb-ecs-task` — el container lo asume (vacío por ahora; agregar policies si se necesita acceso a S3/DynamoDB/etc.)
- State remoto: `s3://mrkrtmn-iac-tfstate/shared/terraform.tfstate` con lock en DynamoDB `tf-locks`

#### Stack `bots/<nombre>/` (uno por bot)
- **ECR repository** (con lifecycle policy: 10 imágenes max, `force_delete=true`)
- **CloudWatch log group** `/ecs/<nombre>` (14 días de retention)
- **SSM Parameter Store SecureString** (uno por cada key en `secret_keys` + `cloudflare-tunnel-token`)
- **ECS task definition** con 2 containers (bot + cloudflared sidecar)
- **ECS service** (`lifecycle.ignore_changes = [task_definition, desired_count]`)
- State remoto: `s3://mrkrtmn-iac-tfstate/bots/<nombre>/terraform.tfstate`

#### Módulo `modules/bot-service/`
Reusable: define los 5 recursos AWS de cada bot. Los stacks `bots/<nombre>/` lo invocan con sus parámetros propios.

### Capa de CI/CD (Jenkins en srv03)

#### Pipeline `iac-apply` (repo `mrkrtmn/IaC`, archivo `Jenkinsfile`)
- Parámetros: `STACK` (shared, bots/faitpro-bot, ...), `ACTION` (plan, apply, destroy), `AUTO_APPROVE` (bool)
- Stages: validate stack → init → validate + plan → approval manual (si !AUTO_APPROVE) → apply/destroy
- Usa la cred `aws-terraform` (IAM user `botwb-iac-terraform`, AdministratorAccess)
- Tool: `terraform` (instalado vía Terraform Plugin de Jenkins, version `1.15.2 linux (amd64)`)

#### Pipeline `botwb-deploy` (repo `mrkrtmn/pipelines`, archivo `botwb.jenkinsfile`)
- Parámetros: `PROJECT` (faitpro-bot, ...), `IMAGE_TAG` (opcional)
- Stages: validate → checkout repo del bot → docker build → push ECR → register task def nueva (con jq edita la imagen) → update-service + wait stable
- Usa la cred `aws-jenkins` (IAM user `botwb-jenkins`, permisos restringidos ECR+ECS+PassRole)

### Capa de aplicación (repo `mrkrtmn/FAITPro-bot`)
- Python 3.11 + FastAPI
- `main.py` — webhook Meta (GET verify + POST con HMAC validation)
- `agent.py` — motor del agente OpenAI con function calling
- `calendar_service.py` — Microsoft Graph / Google Calendar + Mailgun emails
- Dockerfile genérico, configuración por tenant via `config/<tenant>.yml` (env var `TENANT_CONFIG` apunta al path)

## IAM users (out-of-band, NO en terraform)

Gestionados por `scripts/bootstrap-iam.sh`:

- `botwb-jenkins` — pipeline `botwb-deploy` (ECR + ECS + PassRole restrictivo)
- `botwb-iac-terraform` — pipeline `iac-apply` (AdministratorAccess managed policy)

Razón: si terraform los manejara, un `terraform destroy` los borraría, dejando a Jenkins sin permisos para reaplicar (huevo-gallina).

## Network design (decisiones)

- **Sin ALB**: Cloudflare Tunnel hace de "load balancer" lógico (1 task = 1 connector)
- **Sin NAT Gateway** (~$32/mo): tasks corren en subnet pública con `assign_public_ip=true` (~$3.65/mo por task)
- **SG egress-only**: no se pierde nada teniendo IP pública porque el SG bloquea inbound
- **Sin Route 53**: Cloudflare maneja DNS (CNAME `wa-aws.faitpro.com.bo` → `<tunnel-id>.cfargotunnel.com`)

## Multi-tenancy

Para agregar un bot nuevo (ej. `sabornacional`):

1. `cp -r bots/faitpro-bot bots/sabornacional`
2. Editar `bots/sabornacional/backend.tf` (cambiar la key del state a `bots/sabornacional/terraform.tfstate`)
3. Editar `bots/sabornacional/terraform.tfvars` (project_name, secret_keys, tenant_config)
4. Editar `Jenkinsfile` raíz (agregar `bots/sabornacional` al choice del param STACK)
5. Editar `mrkrtmn/pipelines/projects.groovy` (agregar entrada del bot nuevo)
6. Editar `mrkrtmn/pipelines/botwb.jenkinsfile` (agregar al choice del param PROJECT)
7. Commit + push de ambos repos
8. Desde Jenkins: `iac-apply` STACK=bots/sabornacional ACTION=apply
9. Setear SSM con los valores reales del nuevo tenant
10. Crear tunnel en Cloudflare, setear `cloudflare-tunnel-token` en SSM
11. Desde Jenkins: `botwb-deploy` PROJECT=sabornacional
12. `aws ecs update-service --desired-count 1` (sólo la primera vez; queda en 1 para siempre)

Cada bot:
- Tiene su propio ECR, SSM, task def, service, CloudWatch logs
- Comparte VPC, ECS cluster, IAM roles
- Su propio tfvars y state file en S3
- Independiente: destroy/apply de un bot no afecta a los otros
