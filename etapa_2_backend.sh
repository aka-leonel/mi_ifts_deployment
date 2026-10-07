#!/bin/bash
set -e

# ==========================================
# Etapa 2: Despliegue del backend en la EC2 (vía SSM) con RDS Externo
# ==========================================

export AWS_DEFAULT_REGION=us-east-1
export AWS_PAGER=""
source ~/miifts-ids.sh

if [ ! -f ~/miifts-secrets.sh ]; then
  echo "❌ Falta ~/miifts-secrets.sh con los secretos (SECRET_KEY, VAPID_*, SMTP_*)."
  exit 1
fi
source ~/miifts-secrets.sh

if [ -z "$SECRET_KEY" ] || [ -z "$VAPID_PUBLIC_KEY" ] || [ -z "$VAPID_PRIVATE_KEY" ] || [ -z "$SMTP_USER" ] || [ -z "$SMTP_PASSWORD" ]; then
  echo "❌ Faltan secretos en ~/miifts-secrets.sh"
  exit 1
fi

if [ -z "$INSTANCE_ID" ] || [ -z "$DB_HOST" ]; then
  echo "❌ Faltan variables de infraestructura. Ejecuta primero etapa_1_infraestructura_cloud.sh"
  exit 1
fi

echo "=== ESPERANDO A QUE EL AGENTE SSM REGISTRE LA INSTANCIA ==="
PING="None"
for i in $(seq 1 40); do
  PING=$(aws ssm describe-instance-information \
    --filters Key=InstanceIds,Values=$INSTANCE_ID \
    --query 'InstanceInformationList[0].PingStatus' --output text)
  [ "$PING" = "Online" ] && break
  echo "  ...todavía no está disponible ($i/40)"
  sleep 10
done
if [ "$PING" != "Online" ]; then
  echo "❌ La instancia no apareció en SSM."
  exit 1
fi

echo "=== PREPARANDO SCRIPT REMOTO ==="
# Generamos el script inyectando la variable DB_HOST de RDS de manera segura
cat > /tmp/remote_deploy.sh <<REMOTE_EOF
set -e
export DEBIAN_FRONTEND=noninteractive
APT="apt-get -o DPkg::Lock::Timeout=180 -y"

echo "=== 1. INSTALANDO DEPENDENCIAS (DOCKER Y DOCKER COMPOSE) ==="
\$APT update
\$APT install apt-transport-https ca-certificates curl gnupg lsb-release git

if ! command -v docker > /dev/null 2>&1; then
  mkdir -p /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
  echo "deb [arch=\$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \$(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list
  \$APT update
  \$APT install docker-ce docker-ce-cli containerd.io docker-compose-plugin
  usermod -aG docker ubuntu
fi

echo "=== 2. CLONANDO Y DESPLEGANDO EL BACKEND (SOLO API) ==="
cd /home/ubuntu
if [ ! -d "backend-ifts" ]; then
  git clone -b dev https://github.com/aka-leonel/backend-ifts.git
fi
cd backend-ifts
git pull origin dev

# Limpiar el intento anterior (usa el compose del repo, que trae db local)
docker compose down -v --remove-orphans || true

# Crear la base "miifts" en RDS si no existe
DB_EXISTS=\$(docker run --rm -e PGPASSWORD=postgrespassword postgres:16-alpine \
  psql -h ${DB_HOST} -U postgres -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname='miifts'")
if [ "\$DB_EXISTS" != "1" ]; then
  docker run --rm -e PGPASSWORD=postgrespassword postgres:16-alpine \
    psql -h ${DB_HOST} -U postgres -d postgres -c "CREATE DATABASE miifts"
fi

# .env completo: base de datos RDS + auth + push (VAPID) + email (SMTP)
cat > .env <<'ENVEOF'
# --- Base de datos ---
# En el despliegue en AWS se usa RDS (PostgreSQL). La línea de SQLite queda
# comentada porque una segunda DATABASE_URL pisaría a la de RDS.
DATABASE_URL=postgresql://postgres:postgrespassword@${DB_HOST}:5432/miifts
# DATABASE_URL=sqlite:///./miifts.db

CORS_ORIGINS=*

# --- Auth ---
SECRET_KEY=${SECRET_KEY}
ALGORITHM=HS256

# --- Notificaciones push (VAPID) ---
VAPID_PUBLIC_KEY=${VAPID_PUBLIC_KEY}
VAPID_PRIVATE_KEY=${VAPID_PRIVATE_KEY}
VAPID_CLAIMS_SUB=mailto:admin@miifts.com

# --- Email (SMTP) para recuperación de contraseña ---
# Sin SMTP_HOST no se envía nada (solo se loguea un warning, sin el token).
# Gmail: smtp.gmail.com:587 + "contraseña de aplicación" (requiere 2FA), ~500 mails/día gratis.
# Brevo: smtp-relay.brevo.com:587, 300 mails/día gratis.
# Mailtrap (sandbox, no entrega a casillas reales): sandbox.smtp.mailtrap.io:2525.
# AWS SES (a futuro): email-smtp.<region>.amazonaws.com:587 con credenciales SMTP de SES.
SMTP_HOST=smtp-relay.brevo.com
SMTP_PORT=587
SMTP_USER=${SMTP_USER}
SMTP_PASSWORD=${SMTP_PASSWORD}
SMTP_FROM=miiftsinfo@gmail.com
SMTP_STARTTLS=true
ENVEOF

# Compose de producción: solo la API, sin db local y sin tocar el compose del repo
cat > docker-compose.prod.yml <<'COMPOSEEOF'
services:
  api:
    build: .
    env_file: .env
    ports:
      - "8000:8000"
    restart: unless-stopped
COMPOSEEOF
export COMPOSE_FILE=docker-compose.prod.yml
# IMPORTANTE: Asegúrate de que el docker-compose.yml del repositorio 
# haya removido el servicio "db" y solo levante el servicio "api".

docker compose up -d --build


echo "Esperando a que la API responda (migraciones incluidas)..."
UP=0
for i in \$(seq 1 60); do
  CODE=\$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8000/ || true)
  if [ "\$CODE" != "000" ]; then UP=1; break; fi
  sleep 5
done
if [ "\$UP" != "1" ]; then
  echo "❌ La API no respondió en 5 minutos. Últimos logs:"
  docker compose logs --tail 60 api
  exit 1
fi

echo "Ejecutando seed..."
docker exec backend-ifts-api-1 python seed.py

docker compose ps
echo "=== ¡DESPLIEGUE FINALIZADO CON ÉXITO! ==="
REMOTE_EOF

python3 -c 'import json; print(json.dumps({"commands": [open("/tmp/remote_deploy.sh").read()]}))' > /tmp/ssm_params.json

echo "=== ENVIANDO SCRIPT A LA EC2 ==="
COMMAND_ID=$(aws ssm send-command \
    --instance-ids "$INSTANCE_ID" \
    --document-name "AWS-RunShellScript" \
    --timeout-seconds 1800 \
    --parameters file:///tmp/ssm_params.json \
    --query "Command.CommandId" \
    --output text)

STATUS="Pending"
for i in $(seq 1 240); do
  STATUS=$(aws ssm get-command-invocation \
    --command-id "$COMMAND_ID" --instance-id "$INSTANCE_ID" \
    --query Status --output text 2>/dev/null || echo "Pending")
  case "$STATUS" in
    Success|Failed|Cancelled|TimedOut) break ;;
  esac
  sleep 5
done

if [ "$STATUS" != "Success" ]; then
  aws ssm get-command-invocation --command-id "$COMMAND_ID" --instance-id "$INSTANCE_ID" \
  --query '[StandardOutputContent,StandardErrorContent]' --output text | tail -60
  echo "❌ El despliegue del backend falló."
  exit 1
fi

echo "=========================================="
echo "¡ETAPA 2 COMPLETADA!"
echo "Backend: http://$PUBLIC_IP:8000"
echo "=========================================="