#!/bin/bash
set -e

# ==========================================
# Etapa 3: Compilar la PWA y publicarla en la EC2 (servida por Caddy con HTTPS)
# El build viaja a la EC2 por un bucket S3 privado temporal + URL prefirmada.
# ==========================================

export AWS_DEFAULT_REGION=us-east-1
export AWS_PAGER=""

if [ ! -f ~/miifts-ids.sh ]; then
  echo "❌ Falta ~/miifts-ids.sh. Ejecutá primero las etapas 1 y 2."
  exit 1
fi
if [ ! -f ~/miifts-secrets.sh ]; then
  echo "❌ Falta ~/miifts-secrets.sh. Ejecutá primero: ./etapa_0_secrets.sh"
  exit 1
fi
source ~/miifts-ids.sh
source ~/miifts-secrets.sh

REPO_FRONT="https://github.com/aka-leonel/frontend-miifts.git"   # ajustar si cambia

if [ -z "$DOMAIN" ] || [ -z "$INSTANCE_ID" ]; then
  echo "❌ Falta DOMAIN/INSTANCE_ID. Ejecutá primero las etapas 1 y 2."
  exit 1
fi
if [ -z "$VAPID_PUBLIC_KEY" ]; then
  echo "❌ Falta VAPID_PUBLIC_KEY en ~/miifts-secrets.sh. Ejecutá de nuevo: ./etapa_0_secrets.sh"
  exit 1
fi
if ! command -v npm > /dev/null 2>&1; then
  echo "❌ npm no está instalado en este entorno."
  exit 1
fi

# Los archivos temporales se borran siempre al terminar
trap 'rm -f /tmp/remote_front.sh /tmp/ssm_front.json /tmp/dist.tar.gz' EXIT

echo "=== 1. COMPILANDO LA PWA ==="

# Git LFS: las imágenes (*.png) del frontend están guardadas en Git LFS.
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
  git clone -b dev "$REPO_FRONT"
fi
cd frontend-miifts
# El .env está versionado y este script lo reescribe: se descarta el cambio local para poder hacer pull
git checkout -- .env 2>/dev/null || true
git pull origin dev

# Descargar las imágenes reales de LFS (también arregla clones viejos con punteros)
git lfs pull

# Control: si quedó algún puntero LFS en vez de una imagen, cortar acá
# antes de publicar una app rota
if grep -rl --include="*.png" "git-lfs.github.com/spec" src public; then
  echo "❌ Las imágenes de arriba no se descargaron de Git LFS. No se publica."
  exit 1
fi

# La API se consume por el mismo dominio (Caddy la reenvía en /api).
# La clave pública VAPID se compila dentro del front: si se regeneran las claves, hay que repetir esta etapa.
cat > .env <<EOF
VITE_API_URL=https://$DOMAIN/api
VITE_VAPID_PUBLIC_KEY=$VAPID_PUBLIC_KEY
EOF

npm install
npm run build

echo "=== 2. SUBIENDO dist/ A UN BUCKET PRIVADO TEMPORAL ==="
# Si ya existe uno guardado (re-ejecución) se reutiliza. Se guarda ANTES de crearlo
# para que la limpieza (etapa 4) lo encuentre.
if [ -z "${BUCKET_NAME:-}" ]; then
  BUCKET_NAME="$TAG-frontend-bucket-$(date +%s)"
  echo "export BUCKET_NAME=\"$BUCKET_NAME\"" >> ~/miifts-ids.sh
fi
if ! aws s3api head-bucket --bucket "$BUCKET_NAME" 2>/dev/null; then
  aws s3api create-bucket --bucket "$BUCKET_NAME" --region us-east-1
fi

tar -czf /tmp/dist.tar.gz -C dist .
aws s3 cp /tmp/dist.tar.gz s3://$BUCKET_NAME/dist.tar.gz
DIST_URL=$(aws s3 presign s3://$BUCKET_NAME/dist.tar.gz --expires-in 900)

echo "=== 3. PUBLICANDO EN LA EC2 ==="
cat > /tmp/remote_front.sh <<REMOTE_EOF
set -e
curl -fsSL "$DIST_URL" -o /tmp/dist.tar.gz
mkdir -p /home/ubuntu/frontend-dist
rm -rf /home/ubuntu/frontend-dist/*
tar -xzf /tmp/dist.tar.gz -C /home/ubuntu/frontend-dist
rm -f /tmp/dist.tar.gz
ls /home/ubuntu/frontend-dist | head
REMOTE_EOF

python3 -c 'import json; print(json.dumps({"commands": [open("/tmp/remote_front.sh").read()]}))' > /tmp/ssm_front.json

COMMAND_ID=$(aws ssm send-command \
  --instance-ids "$INSTANCE_ID" \
  --document-name "AWS-RunShellScript" \
  --parameters file:///tmp/ssm_front.json \
  --query "Command.CommandId" --output text)

STATUS="Pending"
for i in $(seq 1 60); do
  STATUS=$(aws ssm get-command-invocation \
    --command-id "$COMMAND_ID" --instance-id "$INSTANCE_ID" \
    --query Status --output text 2>/dev/null || echo "Pending")
  case "$STATUS" in
    Success|Failed|Cancelled|TimedOut) break ;;
  esac
  sleep 5
done

if [ "$STATUS" != "Success" ]; then
  echo "❌ Falló la publicación del front ($STATUS)."
  aws ssm get-command-invocation --command-id "$COMMAND_ID" --instance-id "$INSTANCE_ID" \
    --query '[StandardOutputContent,StandardErrorContent]' --output text | tail -20
  exit 1
fi

# El build ya está en la EC2: se borra del bucket (el bucket se elimina en la etapa 4)
aws s3 rm s3://$BUCKET_NAME/dist.tar.gz > /dev/null || true

echo "=== 4. VERIFICANDO HTTPS ==="
CODE="000"
for i in $(seq 1 12); do
  CODE=$(curl -s -o /dev/null -w "%{http_code}" https://$DOMAIN/ || true)
  [ "$CODE" = "200" ] && break
  echo "  ...esperando DNS/certificado ($i/12, código $CODE)"
  sleep 10
done

echo "=================================================="
if [ "$CODE" = "200" ]; then
  echo "✅ ¡FRONTEND DESPLEGADO CON ÉXITO!"
else
  echo "⚠️  Front publicado, pero https://$DOMAIN/ aún no responde 200 (código $CODE)."
  echo "   Puede faltar que se propague el DNS o que Caddy termine de emitir el certificado:"
  echo "   probá de nuevo en unos minutos."
fi
echo "PWA: https://$DOMAIN"
echo "API: https://$DOMAIN/api/"
echo "=================================================="
