#!/bin/bash
set -e

# ==========================================
# Etapa 3: Despliegue del frontend (PWA) en S3
# ==========================================

export AWS_DEFAULT_REGION=us-east-1
source ~/miifts-ids.sh

if [ -z "$PUBLIC_IP" ]; then
  echo "❌ No hay PUBLIC_IP. Ejecuta primero las etapas 1 y 2."
  exit 1
fi
if ! command -v npm > /dev/null 2>&1; then
  echo "❌ npm no está instalado en este entorno."
  exit 1
fi

echo "=== 3. DESPLEGANDO EL FRONTEND EN S3 ==="

cd ~
if [ ! -d "frontend-miifts" ]; then
  git clone -b dev https://github.com/aka-leonel/frontend-miifts.git
fi
cd frontend-miifts
git pull origin dev

# URL del backend con la IP de la EC2
echo "VITE_API_URL=http://$PUBLIC_IP:8000" > .env

# Instalar dependencias y compilar la PWA con Vite
npm install
npm run build

# Nombre del bucket: si ya existe uno guardado (re-ejecución) se reutiliza,
# así no quedan buckets duplicados. Se guarda ANTES de crearlo para que la limpieza lo encuentre.
if [ -z "${BUCKET_NAME:-}" ]; then
  BUCKET_NAME="$TAG-frontend-bucket-$(date +%s)"
  echo "export BUCKET_NAME=\"$BUCKET_NAME\"" >> ~/miifts-ids.sh
fi

if ! aws s3api head-bucket --bucket "$BUCKET_NAME" 2>/dev/null; then
  aws s3api create-bucket --bucket "$BUCKET_NAME" --region us-east-1
fi

# Habilitar acceso público
aws s3api put-public-access-block --bucket "$BUCKET_NAME" \
  --public-access-block-configuration "BlockPublicAcls=false,IgnorePublicAcls=false,BlockPublicPolicy=false,RestrictPublicBuckets=false"

# Política de lectura pública para los objetos
cat > /tmp/bucket_policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "PublicReadGetObject",
      "Effect": "Allow",
      "Principal": "*",
      "Action": "s3:GetObject",
      "Resource": "arn:aws:s3:::$BUCKET_NAME/*"
    }
  ]
}
EOF
aws s3api put-bucket-policy --bucket "$BUCKET_NAME" --policy file:///tmp/bucket_policy.json

# Sitio web estático y subida de archivos
aws s3 website s3://$BUCKET_NAME/ --index-document index.html --error-document index.html
aws s3 sync dist/ s3://$BUCKET_NAME/

echo "=================================================="
echo "✅ ¡FRONTEND DESPLEGADO CON ÉXITO EN S3!"
echo "URL de tu PWA:"
echo "http://$BUCKET_NAME.s3-website-us-east-1.amazonaws.com"
echo "=================================================="