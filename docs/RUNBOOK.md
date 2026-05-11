# Runbook — operaciones diarias

Comandos y procedimientos para las tareas frecuentes.

## Deploy de cambios al código del bot

1. Editar el código en `mrkrtmn/FAITPro-bot`, commit, push a `main`
2. Jenkins → `botwb-deploy` → Build with parameters → `PROJECT=faitpro-bot` → Build
3. ~5 min: build imagen → push ECR → registra task def nueva → `update-service` → `wait services-stable`
4. Verificar: `aws logs tail /ecs/faitpro-bot --since 5m --region us-east-1`

## Deploy de cambios a la infraestructura

1. Editar `IaC/` (terraform), commit, push a `main`
2. Jenkins → `iac-apply` → Build with parameters:
   - `STACK`: el stack que cambió (`shared` o `bots/faitpro-bot`)
   - `ACTION`: `plan` primero para revisar; después `apply` con approval manual
   - `AUTO_APPROVE`: dejar `false` salvo automatización
3. Si action=apply o destroy: el pipeline espera el approval manual mostrando las últimas 80 líneas del plan
4. Aprobar → terraform aplica los cambios

## Cambiar / rotar un secret del bot

```bash
# Ejemplo: rotar OPENAI_API_KEY
aws ssm put-parameter --name "/faitpro-bot/OPENAI_API_KEY" \
  --value "<NUEVO_VALOR>" --type SecureString --overwrite --region us-east-1

# Forzar redeploy para que la nueva task arranque con el secret nuevo
aws ecs update-service --cluster botwb-cluster --service faitpro-bot \
  --force-new-deployment --region us-east-1
```

ECS hace rolling deploy: arranca task nueva, espera healthy, mata la vieja. ~60-90s downtime cero si está en `deployment_minimum_healthy_percent=100` y `maximum_percent=200` (default del módulo).

## Listar todos los secrets (sin valores)

```bash
aws ssm get-parameters-by-path --path "/faitpro-bot/" --recursive --region us-east-1 \
  --query 'Parameters[*].[Name,Type,LastModifiedDate]' --output table
```

## Subir/bajar el bot (escalar)

```bash
# Apagar el bot (sin destruir infra; los secrets quedan)
aws ecs update-service --cluster botwb-cluster --service faitpro-bot \
  --desired-count 0 --region us-east-1

# Encender (vuelve la task)
aws ecs update-service --cluster botwb-cluster --service faitpro-bot \
  --desired-count 1 --region us-east-1
```

El service tiene `lifecycle.ignore_changes = [desired_count]` → estos cambios persisten entre `terraform apply`.

## Ver logs

```bash
# Tail en vivo
aws logs tail /ecs/faitpro-bot --since 5m --follow --region us-east-1

# Sólo errores
aws logs tail /ecs/faitpro-bot --since 1h --region us-east-1 | grep -iE 'error|exception'

# Solo mensajes recibidos
aws logs tail /ecs/faitpro-bot --since 1h --region us-east-1 | grep mensaje_recibido
```

CloudWatch console: https://us-east-1.console.aws.amazon.com/cloudwatch/home?region=us-east-1#logsV2:log-groups/log-group/$252Fecs$252Ffaitpro-bot

## Inspeccionar estado del bot

```bash
# Estado del service
aws ecs describe-services --cluster botwb-cluster --services faitpro-bot --region us-east-1 \
  --query 'services[0].[serviceName,status,desiredCount,runningCount,deployments[0].rolloutState]' --output table

# Task corriendo
aws ecs list-tasks --cluster botwb-cluster --service-name faitpro-bot --region us-east-1

# Detalle de una task
aws ecs describe-tasks --cluster botwb-cluster --tasks <task-arn> --region us-east-1
```

## Apagar bot temporalmente y volver

Útil para mantenimiento o si el bot está respondiendo mal:

```bash
# Apagar
aws ecs update-service --cluster botwb-cluster --service faitpro-bot --desired-count 0 --region us-east-1

# Esperar a que la task muera
aws ecs wait services-stable --cluster botwb-cluster --services faitpro-bot --region us-east-1

# Hacer lo que tengas que hacer...

# Encender
aws ecs update-service --cluster botwb-cluster --service faitpro-bot --desired-count 1 --region us-east-1
```

## Bootstrap completo desde cero

Si por algún motivo hay que recrear todo (cuenta AWS limpia o catástrofe), seguir `README.md` sección "Orden de deploy".

Resumen:
1. `aws s3api create-bucket ...` + DynamoDB (bootstrap del backend)
2. `./scripts/bootstrap-iam.sh` (crea IAM users, muestra access keys)
3. Cargar access keys en Jenkins (creds `aws-jenkins` y `aws-terraform`)
4. Jenkins → `iac-apply` STACK=shared ACTION=apply
5. Jenkins → `iac-apply` STACK=bots/faitpro-bot ACTION=apply
6. Setear los 15 SSM secrets (`scripts/seed-ssm-from-srv05.sh` o manual)
7. Crear el tunnel en Cloudflare, setear `cloudflare-tunnel-token` en SSM
8. Jenkins → `botwb-deploy` PROJECT=faitpro-bot
9. `aws ecs update-service --desired-count 1`

## Troubleshooting

### Bot devuelve HTTP 502

- Verificar el connector cloudflared: `aws logs tail /ecs/faitpro-bot --since 2m --region us-east-1 | grep tunnel`
- Si dice "Tunnel server stopped" + "Application shutdown": la task está reiniciando. Esperar 1 min.
- Si persiste: verificar que `/faitpro-bot/cloudflare-tunnel-token` en SSM tenga un valor real (no `PLACEHOLDER_REPLACE_ME`)

### Bot recibe mensajes pero falla al responder

Si los logs muestran `mensaje_recibido` pero error 401/400 al `Error enviando WhatsApp`:

- **Error 401 (Authentication Error)**: el `META_ACCESS_TOKEN` venció. Generar nuevo (preferentemente System User permanente) y `aws ssm put-parameter` + `force-new-deployment`.
- **Error 400 "Object with ID '...' does not exist"**: el `META_PHONE_NUMBER_ID` no pertenece al WABA al que tu token tiene acceso. Ver `docs/SECRETS.md` para verificar scopes del token.

### `terraform apply` falla por state lock

Si un build de Jenkins quedó colgado, puede dejar lock en DynamoDB. Liberar:

```bash
# Identificar lock
aws dynamodb scan --table-name tf-locks --region us-east-1

# Forzar unlock (cuidado — sólo si estás seguro de que ningún apply legítimo está corriendo)
cd shared/  # o el stack afectado
terraform force-unlock <LOCK_ID>
```

### Una task se queda en `STOPPED` con error

```bash
# Ver task stopped más reciente
aws ecs list-tasks --cluster botwb-cluster --service-name faitpro-bot --desired-status STOPPED --region us-east-1

# Ver razón del stop
aws ecs describe-tasks --cluster botwb-cluster --tasks <task-arn> --region us-east-1 \
  --query 'tasks[0].[stoppedReason,containers[*].[name,reason,exitCode]]'
```

Comunes:
- `ResourceInitializationError: unable to pull secrets` → revisar permisos del IAM role `botwb-ecs-task-execution` y que el SSM param exista.
- `CannotPullContainerError` → ECR vacío (no se hizo push) o tag inexistente.

## Backups del state

Los state files en S3 tienen versioning habilitado. Para restaurar:

```bash
# Listar versiones del state de un stack
aws s3api list-object-versions --bucket mrkrtmn-iac-tfstate --prefix bots/faitpro-bot/terraform.tfstate

# Restaurar una versión anterior
aws s3api copy-object \
  --bucket mrkrtmn-iac-tfstate \
  --copy-source "mrkrtmn-iac-tfstate/bots/faitpro-bot/terraform.tfstate?versionId=<VERSION_ID>" \
  --key bots/faitpro-bot/terraform.tfstate
```
