#!/bin/bash
set -e

source ~/miifts-ids.sh

echo "=== ENVIANDO SCRIPT DE DESPLIEGUE Y CONFIGURACIÓN A LA EC2 ==="

COMMAND_ID=$(aws ssm send-command \
    --instance-ids "$INSTANCE_ID" \
    --document-name "AWS-RunShellScript" \
    --parameters 'commands=["
echo \"=== 1. INSTALANDO DEPENDENCIAS (DOCKER Y DOCKER COMPOSE) ===\"
sudo apt-get update -y
sudo apt-get install -y apt-transport-https ca-certificates curl gnupg lsb-release

# Añadir repositorio oficial de Docker si no está instalado
if ! command -v docker &> /dev/null; then
    sudo mkdir -p /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    echo \"deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable\" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    sudo apt-get update -y
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
    sudo usermod -aG docker ubuntu
fi

echo \"=== 2. CLONANDO Y DESPLEGANDO EL BACKEND ===\"
cd /home/ubuntu
if [ ! -d \"backend-ifts\" ]; then 
  git clone -b dev https://github.com/aka-leonel/backend-ifts.git
fi
cd backend-ifts
git pull origin dev

cat << \"ENVEOF\" > .env
DATABASE_URL=postgresql://postgres:postgres@db:5432/miifts
POSTGRES_USER=postgres
POSTGRES_PASSWORD=postgres
POSTGRES_DB=miifts
CORS_ORIGINS=*
ENVEOF

# Levantar los contenedores usando el plugin moderno de docker
sudo docker compose up -d --build

echo \"Esperando a que la base de datos inicialice...\"
sleep 10
sudo docker exec backend-ifts-api-1 python seed.py || echo \"Aviso: seed ejecutado o pendiente.\"
echo \"=== ¡DESPLIEGUE FINALIZADO CON ÉXITO! ===\"
"]' \
    --query "Command.CommandId" \
    --output text)

echo "Comando SSM enviado (ID: $COMMAND_ID). Esperando ejecución e instalación de Docker (esto puede tomar 1-2 minutos)..."
aws ssm wait command-executed --command-id "$COMMAND_ID" --instance-id "$INSTANCE_ID"

echo "=== RESULTADO DE LA EJECUCIÓN ==="
aws ssm get-command-invocation \
    --command-id "$COMMAND_ID" \
    --instance-id "$INSTANCE_ID" \
    --query "[StandardOutputContent, StandardErrorContent]" \
    --output text

echo "=========================================="
echo "¡ETAPA 2 COMPLETADA!"
echo "=========================================="