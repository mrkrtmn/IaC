#!/usr/bin/env bash
# Repobla los SSM SecureString del bot leyendo .env.faitpro desde srv05.
# Pensado para el bootstrap inicial o si se destruye el stack del bot y hay que
# rellenar los secrets sin re-ingresarlos manualmente.
#
# Skip Twilio legacy y WEBHOOK_URL (no aplican en AWS).
# Los valores NUNCA pasan por la salida del comando (van por pipe a aws ssm).
#
# Pre-requisitos:
#   - SSH a srv05 (puerto 2221) con clave ~/.ssh/id_ed25519_nopass
#   - awscli con creds para escribir SSM en us-east-1
#
# NO setea cloudflare-tunnel-token (ese viene del dashboard CF, no del .env de srv05).

set -euo pipefail

REGION=us-east-1
PROJECT_PREFIX="/faitpro-bot"
SRV05_USER="falcon"
SRV05_HOST="192.168.0.106"
SRV05_PORT="2221"
SRV05_KEY="$HOME/.ssh/id_ed25519_nopass"
ENV_FILE="~/actions-runner-faitpro/_work/FAITPro-bot/FAITPro-bot/.env.faitpro"

echo "=== Leyendo $ENV_FILE de srv05 y seteando SSM ==="

ssh -i "$SRV05_KEY" -p "$SRV05_PORT" -o StrictHostKeyChecking=no "$SRV05_USER@$SRV05_HOST" \
  "cat $ENV_FILE" \
| grep -v '^#' | grep '=' \
| while IFS='=' read -r KEY VALUE; do
    case "$KEY" in
      AZURE_*|CALENDAR_EMAIL|MAILGUN_*|META_*|OPENAI_API_KEY|TELEGRAM_*)
        # Strip quotes y CR si los hay
        VALUE="${VALUE#\"}"; VALUE="${VALUE%\"}"
        VALUE="${VALUE#\'}"; VALUE="${VALUE%\'}"
        VALUE="${VALUE%$'\r'}"
        if aws ssm put-parameter \
              --name "${PROJECT_PREFIX}/${KEY}" \
              --value "$VALUE" \
              --type SecureString \
              --overwrite \
              --region "$REGION" > /dev/null 2>&1; then
          echo "  ✓ $KEY"
        else
          echo "  ✗ $KEY (falló)"
        fi
        ;;
      TWILIO_*|WEBHOOK_URL)
        echo "  - skip $KEY (legacy, no se migra)"
        ;;
      *)
        echo "  ? $KEY (no esperado)"
        ;;
    esac
  done

echo ""
echo "=== Pendiente manual: setear cloudflare-tunnel-token ==="
echo "Obtener token del tunnel 'faitpro-bot-aws' en Cloudflare dashboard y correr:"
echo "  aws ssm put-parameter --name ${PROJECT_PREFIX}/cloudflare-tunnel-token \\"
echo "    --value '<TOKEN>' --type SecureString --overwrite --region $REGION"
echo ""
echo "=== Forzar redeploy para que las tasks tomen los nuevos secrets ==="
echo "  aws ecs update-service --cluster botwb-cluster --service faitpro-bot \\"
echo "    --force-new-deployment --region $REGION"
