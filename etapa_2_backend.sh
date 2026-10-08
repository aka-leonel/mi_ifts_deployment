#!/bin/bash
set -e

# ==========================================
# Etapa 2: Backend en la EC2 (vía SSM) + DuckDNS + Caddy con HTTPS
# ==========================================

export AWS_DEFAULT_REGION=us-east-1
export AWS_PAGER=""

if [ ! -f ~/miifts-ids.sh ]; then
  echo "❌ Falta ~/miifts-ids.sh. Ejecutá primero la etapa 1."
  exit 1
fi
if [ ! -f ~/miifts-secrets.sh ]; then
  echo "❌ Falta ~/miifts-secrets.sh. Ejecutá primero: ./etapa_0_secrets.sh"
  exit 1
fi
source ~/miifts-ids.sh
source ~/miifts-secrets.sh

REPO_BACKEND="https://github.com/aka-leonel/backend-ifts.git"   # ajustar si cambia

# Valores no secretos con default (por si ~/miifts-secrets.sh viene de una versión anterior)
SMTP_HOST="${SMTP_HOST:-smtp-relay.brevo.com}"
SMTP_PORT="${SMTP_PORT:-587}"
SMTP_FROM="${SMTP_FROM:-miiftsinfo@gmail.com}"
VAPID_CLAIMS_SUB="${VAPID_CLAIMS_SUB:-mailto:admin@miifts.com}"

for v in INSTANCE_ID DB_HOST PUBLIC_IP; do
  if [ -z "${!v}" ]; then
    echo "❌ Falta $v. Ejecutá primero la etapa 1."
    exit 1
  fi
done
for v in SECRET_KEY VAPID_PUBLIC_KEY VAPID_PRIVATE_KEY DB_PASSWORD SMTP_USER SMTP_PASSWORD DUCKDNS_SUBDOMAIN DUCKDNS_TOKEN; do
  if [ -z "${!v}" ]; then
    echo "❌ Falta $v en ~/miifts-secrets.sh. Ejecutá de nuevo: ./etapa_0_secrets.sh"
    exit 1
  fi
done

DOMAIN="${DUCKDNS_SUBDOMAIN}.duckdns.org"

echo "=== ACTUALIZANDO DUCKDNS ($DOMAIN -> $PUBLIC_IP) ==="
RES=$(curl -s --max-time 30 "https://www.duckdns.org/update?domains=${DUCKDNS_SUBDOMAIN}&token=${DUCKDNS_TOKEN}&ip=${PUBLIC_IP}" || true)
if [ "$RES" != "OK" ]; then
  echo "❌ DuckDNS respondió: '${RES}' (revisá el subdominio y el token)."
  exit 1
fi
# Se guarda el dominio para la etapa 3 (reemplaza el anterior si cambió el subdominio)
sed -i '/^export DOMAIN=/d' ~/miifts-ids.sh
echo "export DOMAIN=\"$DOMAIN\"" >> ~/miifts-ids.sh

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
# Los archivos temporales contienen secretos: se borran siempre al terminar
trap 'rm -f /tmp/remote_deploy.sh /tmp/ssm_params.json' EXIT

# Las variables sin escapar se reemplazan acá (en CloudShell); las que llevan \ se evalúan en la EC2
cat > /tmp/remote_deploy.sh <<REMOTE_EOF
set -e
export DEBIAN_FRONTEND=noninteractive
APT="apt-get -o DPkg::Lock::Timeout=180 -y"

echo "=== 1. INSTALANDO DEPENDENCIAS (DOCKER) ==="
\$APT update
\$APT install apt-transport-https ca-certificates curl gnupg lsb-release git

if ! command -v docker > /dev/null 2>&1; then
  mkdir -p /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
  echo "deb [arch=\$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \$(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list
  \$APT update
  \$APT install docker-ce docker-ce-cli containerd.io
  usermod -aG docker ubuntu
fi

echo "=== 2. CLONANDO Y DESPLEGANDO EL BACKEND (SOLO API) ==="
cd /home/ubuntu
if [ ! -d "backend-ifts" ]; then
  git clone -b dev ${REPO_BACKEND}
fi
cd backend-ifts
git pull origin dev

# .env completo: base de datos RDS + auth + push (VAPID) + email (SMTP) + link de recuperación
# (la base "miifts" ya la creó la etapa 1 junto con la instancia RDS)
cat > .env <<'ENVEOF'
# --- Base de datos (RDS) ---
DATABASE_URL=postgresql+psycopg2://postgres:${DB_PASSWORD}@${DB_HOST}:5432/miifts

# --- Auth ---
SECRET_KEY=${SECRET_KEY}
ALGORITHM=HS256
CORS_ORIGINS=https://${DOMAIN}
PORT=8000

# --- Notificaciones push (VAPID) ---
VAPID_PUBLIC_KEY=${VAPID_PUBLIC_KEY}
VAPID_PRIVATE_KEY=${VAPID_PRIVATE_KEY}
VAPID_CLAIMS_SUB=${VAPID_CLAIMS_SUB}

# --- Email (SMTP) para recuperación de contraseña ---
# Sin SMTP_HOST no se envía nada (solo se loguea un warning, sin el token).
SMTP_HOST=${SMTP_HOST}
SMTP_PORT=${SMTP_PORT}
SMTP_USER=${SMTP_USER}
SMTP_PASSWORD=${SMTP_PASSWORD}
SMTP_FROM=${SMTP_FROM}
SMTP_STARTTLS=true

# --- Link del mail de recuperación de contraseña ---
# Sin esta variable el backend usa http://localhost:5173/reset-password.
FRONTEND_RESET_PASSWORD_URL=https://${DOMAIN}/reset-password
ENVEOF
chmod 600 .env

docker build -t miifts-api .
docker rm -f miifts-api 2>/dev/null || true
docker run -d --name miifts-api --restart unless-stopped --network host --env-file .env miifts-api

echo "Esperando a que la API responda (migraciones incluidas)..."
UP=0
for i in \$(seq 1 60); do
  CODE=\$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8000/ || true)
  if [ "\$CODE" != "000" ]; then UP=1; break; fi
  sleep 5
done
if [ "\$UP" != "1" ]; then
  echo "❌ La API no respondió en 5 minutos. Últimos logs:"
  docker logs --tail 60 miifts-api
  exit 1
fi

echo "Ejecutando seed..."
docker exec miifts-api python seed.py

echo "=== 3. CADDY (HTTPS) ==="
# Caddy obtiene y renueva solo el certificado de Let's Encrypt para el dominio.
# /api/* se reenvía a la API (sin el prefijo /api); el resto sirve la PWA (la publica la etapa 3).
mkdir -p /home/ubuntu/frontend-dist /home/ubuntu/caddy
cat > /home/ubuntu/caddy/Caddyfile <<'CADDY'
${DOMAIN} {
  encode gzip
  handle_path /api/* {
    reverse_proxy localhost:8000
  }
  handle {
    root * /srv
    try_files {path} /index.html
    file_server
  }
}
CADDY
docker rm -f caddy 2>/dev/null || true
docker run -d --name caddy --restart unless-stopped --network host \
  -v /home/ubuntu/caddy/Caddyfile:/etc/caddy/Caddyfile \
  -v /home/ubuntu/frontend-dist:/srv \
  -v caddy_data:/data \
  caddy:2

docker ps
echo "=== ¡BACKEND DESPLEGADO CON ÉXITO! ==="
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
  echo "❌ El despliegue del backend falló ($STATUS)."
  exit 1
fi

echo "=========================================="
echo "¡ETAPA 2 COMPLETADA!"
echo "Dominio: https://$DOMAIN (la PWA se publica en la etapa 3)"
echo "API:     https://$DOMAIN/api/"
echo "=========================================="
