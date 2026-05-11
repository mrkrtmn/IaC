project_name  = "faitpro-bot"
tenant_config = "config/faitpro.yml"

secret_keys = [
  "OPENAI_API_KEY",
  "META_PHONE_NUMBER_ID",
  "META_ACCESS_TOKEN",
  "META_APP_SECRET",
  "META_VERIFY_TOKEN",
  "TELEGRAM_BOT_TOKEN",
  "TELEGRAM_CHAT_ID",
  "AZURE_TENANT_ID",
  "AZURE_CLIENT_ID",
  "AZURE_CLIENT_SECRET",
  "CALENDAR_EMAIL",
  "MAILGUN_API_KEY",
  "MAILGUN_DOMAIN",
  "MAILGUN_FROM_EMAIL",
]

cpu           = 256
memory        = 512
desired_count = 1
