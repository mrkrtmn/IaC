# Gestión de secrets

Los secrets viven en **3 lugares distintos** según para qué se usan. NO hay `.env` en ningún lado de AWS.

## Mapa de secrets

| Tipo | Dónde vive | Quién lo lee |
|---|---|---|
| Secrets de la app (bot) | **AWS SSM Parameter Store** (SecureString) | ECS al arrancar la task |
| Secrets de Jenkins | **Jenkins Credentials Store** | Pipelines (`iac-apply`, `botwb-deploy`) |
| Backend state encryption | KMS managed (`alias/aws/ssm`, `alias/aws/s3`) | AWS automático |

## 1. Secrets de la app (AWS SSM)

15 SSM SecureString params bajo el prefix `/faitpro-bot/`:

| Key | Para qué |
|---|---|
| `OPENAI_API_KEY` | Llamadas a `api.openai.com` (chat completions, function calling) |
| `META_PHONE_NUMBER_ID` | ID del número WhatsApp en Cloud API (qué número usa el bot para enviar) |
| `META_ACCESS_TOKEN` | Token para enviar/recibir mensajes via Meta WhatsApp Cloud API |
| `META_APP_SECRET` | Para validar HMAC-SHA256 de los webhooks entrantes |
| `META_VERIFY_TOKEN` | Para el GET /webhook de verificación inicial (handshake con Meta) |
| `TELEGRAM_BOT_TOKEN` | Bot @FAITPro_WP_bot, para notificar prospectos al admin |
| `TELEGRAM_CHAT_ID` | Chat ID del admin (1167495609 — Franz) |
| `AZURE_TENANT_ID` | Microsoft Graph API (Azure AD tenant) |
| `AZURE_CLIENT_ID` | Microsoft Graph API (app ID) |
| `AZURE_CLIENT_SECRET` | Microsoft Graph API (app secret) |
| `CALENDAR_EMAIL` | Email del calendario (calendario donde se crean los eventos) |
| `MAILGUN_API_KEY` | Mailgun API key (envío de emails de invitación) |
| `MAILGUN_DOMAIN` | Mailgun sending domain |
| `MAILGUN_FROM_EMAIL` | From address de los emails |
| `cloudflare-tunnel-token` | Token del connector del tunnel `faitpro-bot-aws` (lo lee el sidecar cloudflared) |

### Cómo se inyectan al container

En `modules/bot-service/main.tf`, el `aws_ecs_task_definition` define `secrets[].valueFrom` por cada SSM param:

```hcl
secrets = [
  { name = "OPENAI_API_KEY", valueFrom = aws_ssm_parameter.app["OPENAI_API_KEY"].arn },
  { name = "META_ACCESS_TOKEN", valueFrom = aws_ssm_parameter.app["META_ACCESS_TOKEN"].arn },
  ...
]
```

ECS lee el SSM param al arrancar la task (usando el `task_execution_role`) y lo inyecta como env var al proceso. El código del bot lo lee con `os.environ['OPENAI_API_KEY']`.

### Cómo setear / rotar

```bash
aws ssm put-parameter --name "/faitpro-bot/<KEY>" \
  --value "<VALOR>" --type SecureString --overwrite --region us-east-1

# Para que el bot tome el nuevo valor, force-redeploy:
aws ecs update-service --cluster botwb-cluster --service faitpro-bot \
  --force-new-deployment --region us-east-1
```

⚠️ El secret no se inyecta dinámicamente; se inyecta al arrancar la task. Por eso es necesario el redeploy.

### Encriptación

Por default usa la KMS key `alias/aws/ssm` (AWS-managed, gratis). Si querés una key propia, pasar `key_id = "..."` al `aws_ssm_parameter` (no hay razón hasta ahora).

## 2. Secrets de Jenkins

Configurados en https://jenkins.faitpro.com.bo/credentials/ → Global:

| ID | Tipo | Para qué |
|---|---|---|
| `aws-jenkins` | Username/password | AWS creds del user `botwb-jenkins` (lo usa `botwb-deploy`) |
| `aws-terraform` | Username/password | AWS creds del user `botwb-iac-terraform` (lo usa `iac-apply`) |
| `github-pat` | Username/password | PAT de GitHub para clonar repos privados |

Las dos creds AWS son `Username = AWS_ACCESS_KEY_ID`, `Password = AWS_SECRET_ACCESS_KEY`.

### Cómo regenerar las creds AWS

Si una de las access keys de los IAM users de Jenkins se compromete:

```bash
# 1. Identificar la access key vieja
aws iam list-access-keys --user-name botwb-jenkins

# 2. Crear una nueva
aws iam create-access-key --user-name botwb-jenkins
# Copiar el AccessKeyId y SecretAccessKey de la salida

# 3. Actualizar la cred en Jenkins (UI o API)
# Manage Jenkins → Credentials → System → Global → aws-jenkins → Update

# 4. Borrar la vieja
aws iam delete-access-key --user-name botwb-jenkins --access-key-id <VIEJA_KEY_ID>
```

Mismo procedimiento para `botwb-iac-terraform`.

## 3. Meta WhatsApp — System User token permanente

Importante porque los tokens temporales que genera Meta en la app dashboard expiran en **24 horas**. Para producción se usa un **System User token** que **NO expira**.

### Cómo se generó (referencia)

1. https://business.facebook.com/settings/system-users (Business `FAITPro`)
2. Click **"Agregar"** → nombre `faitpro` → rol Admin
3. Click sobre el user `faitpro` → **"Asignar activos"**:
   - **Ronda 1** — tipo *Apps*: marcar `FAITPro Bot`, permiso **"Administrar app"** (control total)
   - **Ronda 2** — tipo *Cuentas de WhatsApp*: marcar los WABAs (`1709550650400080` viejo + `1315055643906907` nuevo), permiso **"Control total"**
4. Click **"Generar token"**:
   - App: `FAITPro Bot`
   - Caducidad: **Nunca**
   - Permisos: `whatsapp_business_messaging` + `whatsapp_business_management`
5. Copiar el token (se muestra una sola vez) → setear en SSM:
   ```bash
   aws ssm put-parameter --name "/faitpro-bot/META_ACCESS_TOKEN" \
     --value "<TOKEN>" --type SecureString --overwrite --region us-east-1
   aws ecs update-service --cluster botwb-cluster --service faitpro-bot \
     --force-new-deployment --region us-east-1
   ```

### Cómo verificar el token

```bash
TOKEN=$(aws ssm get-parameter --name "/faitpro-bot/META_ACCESS_TOKEN" --with-decryption --region us-east-1 --query 'Parameter.Value' --output text)

curl -sS "https://graph.facebook.com/debug_token?input_token=$TOKEN&access_token=$TOKEN" \
  | jq '.data | {is_valid, type, expires_at, scopes}'
```

Salida esperada:
```json
{
  "is_valid": true,
  "type": "SYSTEM_USER",
  "expires_at": 0,          // 0 = nunca expira
  "scopes": ["whatsapp_business_management", "whatsapp_business_messaging", "public_profile"]
}
```

### Si el token tiene scopes limitados

`granular_scopes` con `target_ids` = lista de WABAs sobre los que el token tiene acceso. Si querés agregar otro WABA:

1. Business Manager → System Users → `faitpro` → **Agregar activos** → seleccionar el WABA nuevo con permisos "Control total"
2. **Generar token nuevo** (los tokens existentes no se actualizan retroactivamente con los nuevos scopes — hay que generar uno nuevo)
3. Setear el nuevo en SSM (override `META_ACCESS_TOKEN`)

## 4. Webhook de Meta (no es exactamente secret pero relacionado)

Configuración en **developers.facebook.com → FAITPro Bot → WhatsApp → Configuration → Webhook**:

- Callback URL: `https://wa-aws.faitpro.com.bo/webhook`
- Verify token: `faitpro_verify_2026` (debe coincidir con `META_VERIFY_TOKEN` en SSM)
- Suscribir a: `messages`

Para cambiar el verify token:
1. Actualizar el SSM: `aws ssm put-parameter --name "/faitpro-bot/META_VERIFY_TOKEN" --value "<NUEVO>" ...`
2. En Meta dashboard, también actualizar el "Verify token" del webhook (debe coincidir)
3. Meta hace un GET de verificación; si los dos coinciden, la suscripción se mantiene

## 5. Por qué SSM y no Jenkins para los secrets del bot

Trade-offs evaluados:

| | SSM (lo que hicimos) | Jenkins Credentials |
|---|---|---|
| Lectura en runtime (sin Jenkins) | ✓ ECS lee directo | ✗ Requeriría que Jenkins reinicie el bot cada vez |
| Auto-recovery de ECS | ✓ Nueva task lee SSM al arrancar | ✗ Si Jenkins no está disponible, no arranca |
| Costo | $0 (Standard tier) | $0 |
| Rotación sin redeploy | ✗ Necesita `force-new-deployment` | ✗ Mismo |
| Secretos en imagen Docker | ✓ Nunca tocan la imagen | ⚠️ Si se pasan como env vars en docker build, sí |
| Visibilidad fuera de Jenkins | ✓ awscli, consola | ✗ Sólo Jenkins UI/API |

## srv05 — legacy

El `.env.faitpro` en `~/actions-runner-faitpro/_work/FAITPro-bot/FAITPro-bot/.env.faitpro` en srv05 **ya no se usa** desde que migramos a AWS. Se conservó porque sirvió de fuente para el primer poblado de SSM. Puede borrarse cuando se quiera. Si se borra, los valores siguen en SSM (no se pierde nada).
