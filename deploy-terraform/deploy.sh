#!/bin/bash
set -e

# ==========================================
# deploy.sh - Despliegue automatizado de miIFTS con Terraform
# AWS Academy Learner Lab (us-east-1)
# ==========================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="$SCRIPT_DIR/terraform"

echo "=== CREDENCIALES DE AWS ACADEMY ==="
echo "Pegá el bloque completo que copiás del panel de Learner Lab (AWS Details > AWS CLI),"
echo "las 3 líneas 'export AWS_...', y terminá con una línea vacía (Enter):"
echo ""

CREDS=""
while IFS= read -r line; do
  [ -z "$line" ] && break
  CREDS="$CREDS
$line"
done

eval "$CREDS" 2>/dev/null || true

if [ -z "$AWS_ACCESS_KEY_ID" ] || [ -z "$AWS_SECRET_ACCESS_KEY" ] || [ -z "$AWS_SESSION_TOKEN" ]; then
  echo "❌ No se detectaron las 3 credenciales (AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_SESSION_TOKEN)."
  echo "   Verificá que pegaste el bloque completo tal cual lo copiaste de Learner Lab."
  exit 1
fi

export AWS_ACCESS_KEY_ID
export AWS_SECRET_ACCESS_KEY
export AWS_SESSION_TOKEN
export AWS_DEFAULT_REGION=us-east-1
export AWS_PAGER=""

echo "✅ Credenciales cargadas para esta sesión (no se escriben en ningún archivo)."

echo ""
echo "=== 1. TERRAFORM INIT / APPLY (infraestructura: VPC, EC2, RDS, S3) ==="
cd "$TF_DIR"
terraform init -input=false
terraform apply -auto-approve

INSTANCE_ID=$(terraform output -raw instance_id)
PUBLIC_IP=$(terraform output -raw backend_public_ip)
DB_HOST=$(terraform output -raw db_host)
DB_NAME=$(terraform output -raw db_name)
DB_USERNAME=$(terraform output -raw db_username)
DB_PASSWORD=$(terraform output -raw db_password)
BUCKET_NAME=$(terraform output -raw bucket_name)
BACKEND_REPO_URL=$(terraform output -raw backend_repo_url)
BACKEND_REPO_BRANCH=$(terraform output -raw backend_repo_branch)
FRONTEND_REPO_URL=$(terraform output -raw frontend_repo_url)
FRONTEND_REPO_BRANCH=$(terraform output -raw frontend_repo_branch)

cd "$SCRIPT_DIR"

echo ""
echo "=== 2. ESPERANDO A QUE EL AGENTE SSM REGISTRE LA INSTANCIA ==="
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

echo ""
echo "=== 3. DESPLEGANDO EL BACKEND EN LA EC2 (vía SSM) ==="
cat > /tmp/remote_deploy.sh <<REMOTE_EOF
set -e
export DEBIAN_FRONTEND=noninteractive
APT="apt-get -o DPkg::Lock::Timeout=180 -y"

echo "=== Instalando Docker y Docker Compose ==="
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

echo "=== Clonando y desplegando el backend ==="
cd /home/ubuntu
if [ ! -d "backend-ifts" ]; then
  git clone -b $BACKEND_REPO_BRANCH $BACKEND_REPO_URL
fi
cd backend-ifts
git pull origin $BACKEND_REPO_BRANCH

cat > .env <<ENVEOF
DATABASE_URL=postgresql://$DB_USERNAME:$DB_PASSWORD@$DB_HOST:5432/$DB_NAME
CORS_ORIGINS=*
ENVEOF

# El docker-compose.yml del repo debe tener solo el servicio "api" (sin "db" local)
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
echo "=== Backend desplegado con éxito ==="
REMOTE_EOF

python3 -c 'import json; print(json.dumps({"commands": [open("/tmp/remote_deploy.sh").read()]}))' > /tmp/ssm_params.json

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
  echo "❌ El despliegue del backend falló (status: $STATUS)."
  echo "   Revisá los detalles con:"
  echo "   aws ssm get-command-invocation --command-id $COMMAND_ID --instance-id $INSTANCE_ID"
  exit 1
fi
echo "✅ Backend arriba en http://$PUBLIC_IP:8000"

echo ""
echo "=== 4. DESPLEGANDO EL FRONTEND EN S3 ==="
if ! command -v npm > /dev/null 2>&1; then
  echo "❌ npm no está instalado en este entorno."
  exit 1
fi

cd ~
if [ ! -d "frontend-miifts" ]; then
  git clone -b "$FRONTEND_REPO_BRANCH" "$FRONTEND_REPO_URL"
fi
cd frontend-miifts
git pull origin "$FRONTEND_REPO_BRANCH"

echo "VITE_API_URL=http://$PUBLIC_IP:8000" > .env

npm install
npm run build

aws s3 sync dist/ "s3://$BUCKET_NAME/" --delete

echo ""
echo "=========================================="
echo "✅ DESPLIEGUE COMPLETO"
echo "Backend:  http://$PUBLIC_IP:8000"
echo "Frontend: http://$BUCKET_NAME.s3-website-us-east-1.amazonaws.com"
echo "RDS:      $DB_HOST"
echo "=========================================="
