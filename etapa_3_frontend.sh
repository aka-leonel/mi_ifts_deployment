#!/bin/bash
set -e

# Cargar las variables de red
source ~/miifts-ids.sh

echo "=== 3. DESPLEGANDO EL FRONTEND EN S3 ==="

cd ~
if [ ! -d "frontend-miifts" ]; then 
  git clone -b dev https://github.com/aka-leonel/frontend-miifts.git
fi
cd frontend-miifts
git pull origin dev

# Configurar la URL del backend dinámicamente con la IP de la EC2
echo "VITE_API_URL=http://$PUBLIC_IP:8000" > .env

# Instalar dependencias y compilar la PWA con Vite
npm install
npm run build

# Crear bucket único de S3
BUCKET_NAME="$TAG-frontend-bucket-$(date +%s)"
aws s3api create-bucket --bucket $BUCKET_NAME --region us-east-1

# Habilitar acceso público
aws s3api put-public-access-block --bucket $BUCKET_NAME \
  --public-access-block-configuration "BlockPublicAcls=false,IgnorePublicAcls=false,BlockPublicPolicy=false,RestrictPublicBuckets=false"

# Aplicar política de lectura pública para los objetos
aws s3api put-bucket-policy --bucket $BUCKET_NAME --policy "{
  \"Version\": \"2012-10-17\",
  \"Statement\": [
    {
      \"Sid\": \"PublicReadGetObject\",
      \"Effect\": \"Allow\",
      \"Principal\": \"*\",
      \"Action\": \"s3:GetObject\",
      \"Resource\": \"arn:aws:s3:::$BUCKET_NAME/*\"
    }
  ]
}"

# Configurar el bucket como sitio web estático y subir los archivos
aws s3 website s3://$BUCKET_NAME/ --index-document index.html --error-document index.html
aws s3 sync dist/ s3://$BUCKET_NAME/

echo "=================================================="
echo "✅ ¡FRONTEND DESPLEGADO CON ÉXITO EN S3!"
echo "URL de tu PWA:"
echo "http://$BUCKET_NAME.s3-website-us-east-1.amazonaws.com"
echo "=================================================="