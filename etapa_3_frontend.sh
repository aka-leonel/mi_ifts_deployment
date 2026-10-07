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

# [NUEVO] Git LFS: las imágenes (*.png) del frontend están guardadas en Git LFS.
# Sin git-lfs el clone baja "punteros" de texto en vez de las imágenes y la app
# se publica sin logo ni íconos. CloudShell no lo trae instalado.
export PATH="$HOME/bin:$PATH"
if ! command -v git-lfs > /dev/null 2>&1; then
  echo "Instalando git-lfs..."
  if ! sudo dnf install -y git-lfs > /dev/null 2>&1; then
    # Plan B: bajar el binario oficial desde GitHub (no necesita dnf)
    LFS_VERSION="3.5.1"
    case "$(uname -m)" in
      aarch64) LFS_ARCH="arm64" ;;
      *)       LFS_ARCH="amd64" ;;
    esac
    curl -fsSL "https://github.com/git-lfs/git-lfs/releases/download/v${LFS_VERSION}/git-lfs-linux-${LFS_ARCH}-v${LFS_VERSION}.tar.gz" | tar -xz -C /tmp
    mkdir -p ~/bin
    cp "/tmp/git-lfs-${LFS_VERSION}/git-lfs" ~/bin/
  fi
fi
git lfs install

cd ~
if [ ! -d "frontend-miifts" ]; then
  git clone -b dev https://github.com/aka-leonel/frontend-miifts.git
fi
cd frontend-miifts
git pull origin dev

# [NUEVO] Descargar las imágenes reales de LFS (también arregla clones viejos
# que hayan quedado con punteros de una ejecución anterior)
git lfs pull

# [NUEVO] Control: si quedó algún puntero LFS en vez de una imagen, cortar acá
# antes de publicar una app rota
if grep -rl --include="*.png" "git-lfs.github.com/spec" src public; then
  echo "❌ Las imágenes de arriba no se descargaron de Git LFS. No se publica."
  exit 1
fi

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