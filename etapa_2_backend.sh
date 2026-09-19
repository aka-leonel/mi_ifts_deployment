#!/bin/bash
set -e

# Cargar las variables de red creadas en la etapa 1
source ~/miifts-ids.sh

echo "=== CONECTANDO A LA EC2 PARA DESPLEGAR EL BACKEND ==="

# Ejecutar comandos dentro de la instancia EC2 usando AWS SSM
aws ssm start-session --target $INSTANCE_ID --document-name AWS-StartInteractiveCommand --parameters command="sudo su - ubuntu << 'EOF'
cd ~
if [ ! -d 'backend-ifts' ]; then 
  git clone -b dev https://github.com/aka-leonel/backend-ifts.git
fi
cd backend-ifts
git pull origin dev

# Crear archivo de entorno para Docker Compose
cat << 'ENVEOF' > .env
DATABASE_URL=postgresql://postgres:postgres@db:5432/miifts
POSTGRES_USER=postgres
POSTGRES_PASSWORD=postgres
POSTGRES_DB=miifts
CORS_ORIGINS=*
ENVEOF

# Levantar los contenedores
sudo docker compose up -d --build

# Esperar a que la base de datos esté lista y ejecutar el seed
echo 'Esperando a que la base de datos inicialice...'
sleep 5
sudo docker exec backend-ifts-api-1 python seed.py

echo '=== BACKEND DESPLEGADO Y POBLADO EXITOSAMENTE ==='
EOF
"