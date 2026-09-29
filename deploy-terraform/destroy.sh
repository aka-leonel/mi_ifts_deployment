#!/bin/bash
set -e

# ==========================================
# destroy.sh - Elimina TODOS los recursos de miIFTS creados por Terraform
# ==========================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="$SCRIPT_DIR/terraform"

echo "=== CREDENCIALES DE AWS ACADEMY ==="
echo "Pegá el bloque de credenciales (3 líneas 'export AWS_...') y terminá con una línea vacía (Enter):"
echo ""

CREDS=""
while IFS= read -r line; do
  [ -z "$line" ] && break
  CREDS="$CREDS
$line"
done

eval "$CREDS" 2>/dev/null || true

if [ -z "$AWS_ACCESS_KEY_ID" ] || [ -z "$AWS_SECRET_ACCESS_KEY" ] || [ -z "$AWS_SESSION_TOKEN" ]; then
  echo "❌ No se detectaron las 3 credenciales."
  exit 1
fi

export AWS_ACCESS_KEY_ID
export AWS_SECRET_ACCESS_KEY
export AWS_SESSION_TOKEN
export AWS_DEFAULT_REGION=us-east-1
export AWS_PAGER=""

echo "✅ Credenciales cargadas."
echo ""
echo "=== TERRAFORM DESTROY (RDS, EC2, S3, VPC y todo lo asociado) ==="
cd "$TF_DIR"
terraform destroy -auto-approve

echo ""
echo "✅ Limpieza completa. No debería quedar ningún recurso de miifts-* en la cuenta."
