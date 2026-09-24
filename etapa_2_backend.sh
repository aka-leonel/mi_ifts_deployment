#!/bin/bash
set -e

# ==========================================
# Etapa 2: Despliegue del backend en la EC2 (vía SSM)
# ==========================================

export AWS_DEFAULT_REGION=us-east-1
export AWS_PAGER=""
source ~/miifts-ids.sh

if [ -z "$INSTANCE_ID" ]; then
  echo "❌ No hay INSTANCE_ID. Ejecuta primero etapa_1_infraestructura_cloud.sh"
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
  echo "❌ La instancia no apareció en SSM. Revisa que tenga el rol LabInstanceProfile y salida a internet."
  exit 1
fi

echo "=== PREPARANDO SCRIPT REMOTO ==="
# El script que corre dentro de la EC2 va en un archivo aparte (heredoc con comillas:
# no se expande nada localmente) y luego se convierte a JSON para evitar problemas de escapes.
cat > /tmp/remote_deploy.sh <<'REMOTE_EOF'
set -e
export DEBIAN_FRONTEND=noninteractive
APT="apt-get -o DPkg::Lock::Timeout=180 -y"

echo "=== 1. INSTALANDO DEPENDENCIAS (DOCKER Y DOCKER COMPOSE) ==="
$APT update
$APT install apt-transport-https ca-certificates curl gnupg lsb-release git

if ! command -v docker > /dev/null 2>&1; then
  mkdir -p /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list
  $APT update
  $APT install docker-ce docker-ce-cli containerd.io docker-compose-plugin
  usermod -aG docker ubuntu
fi

echo "=== 2. CLONANDO Y DESPLEGANDO EL BACKEND ==="
cd /home/ubuntu
if [ ! -d "backend-ifts" ]; then
  git clone -b dev https://github.com/aka-leonel/backend-ifts.git
fi
cd backend-ifts
git pull origin dev

cat > .env <<'ENVEOF'
DATABASE_URL=postgresql://postgres:postgres@db:5432/miifts
POSTGRES_USER=postgres
POSTGRES_PASSWORD=postgres
POSTGRES_DB=miifts
CORS_ORIGINS=*
ENVEOF

docker compose up -d --build

echo "Esperando a que la API responda (migraciones incluidas)..."
UP=0
for i in $(seq 1 60); do
  CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8000/ || true)
  if [ "$CODE" != "000" ]; then UP=1; break; fi
  sleep 5
done
if [ "$UP" != "1" ]; then
  echo "❌ La API no respondió en 5 minutos. Últimos logs:"
  docker compose logs --tail 60 api
  exit 1
fi

# Se ejecuta una sola vez (no se reintenta, porque no se sabe si el seed es idempotente)
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

echo "Comando SSM enviado (ID: $COMMAND_ID). Esperando ejecución (puede tardar varios minutos)..."

# Polling propio: el waiter de la CLI se rinde a los ~100 segundos
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

echo "=== RESULTADO DE LA EJECUCIÓN (estado: $STATUS) ==="
aws ssm get-command-invocation \
    --command-id "$COMMAND_ID" \
    --instance-id "$INSTANCE_ID" \
    --query "[StandardOutputContent, StandardErrorContent]" \
    --output text

if [ "$STATUS" != "Success" ]; then
  echo "❌ El despliegue del backend no terminó bien (estado: $STATUS)."
  exit 1
fi

echo "=== VERIFICANDO QUE EL BACKEND RESPONDE DESDE AFUERA ==="
HTTP="000"
for i in $(seq 1 12); do
  HTTP=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 http://$PUBLIC_IP:8000/docs || true)
  [ "$HTTP" != "000" ] && break
  sleep 5
done
if [ "$HTTP" = "000" ]; then
  echo "❌ El backend no responde en http://$PUBLIC_IP:8000 (revisa el Security Group y los logs)."
  exit 1
fi
echo "Respuesta HTTP de /docs: $HTTP"

echo "=========================================="
echo "¡ETAPA 2 COMPLETADA!"
echo "Backend: http://$PUBLIC_IP:8000"
echo "=========================================="