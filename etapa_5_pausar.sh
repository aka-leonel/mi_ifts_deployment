#!/bin/bash
# ==========================================
# Etapa 5: Pausar el entorno (sin destruir nada)
# Detiene EC2 y RDS para dejar de pagar cómputo por hora,
# pero conserva VPC, subredes, SGs, discos y LOS DATOS de la base.
# ==========================================

export AWS_DEFAULT_REGION=us-east-1
export AWS_PAGER=""
IDS_FILE=~/miifts-ids.sh

if [ ! -f "$IDS_FILE" ]; then
  echo "❌ No encuentro $IDS_FILE. ¿Hay un despliegue activo?"
  exit 1
fi
source "$IDS_FILE"

if [ -z "$INSTANCE_ID" ] || [ -z "$DB_INSTANCE_IDENTIFIER" ]; then
  echo "❌ Faltan INSTANCE_ID o DB_INSTANCE_IDENTIFIER en $IDS_FILE."
  exit 1
fi

echo "=== DETENIENDO INSTANCIA EC2 ($INSTANCE_ID) ==="
aws ec2 stop-instances --instance-ids "$INSTANCE_ID" > /dev/null
aws ec2 wait instance-stopped --instance-ids "$INSTANCE_ID"
echo "EC2 detenida."

echo "=== DETENIENDO INSTANCIA RDS ($DB_INSTANCE_IDENTIFIER) ==="
aws rds stop-db-instance --db-instance-identifier "$DB_INSTANCE_IDENTIFIER" > /dev/null
echo "RDS deteniéndose (puede tardar unos minutos en pasar a estado 'stopped')."
echo "⚠️  Nota: AWS reactiva automáticamente una RDS detenida a los 7 días."

echo "=========================================="
echo "✅ Entorno pausado. VPC, subredes, SGs, discos EBS y los datos"
echo "   de la base siguen existiendo — solo se dejó de pagar cómputo."
echo "⚠️  Al reanudar, la EC2 va a tener una IP pública NUEVA (no usa"
echo "   Elastic IP). Vas a necesitar re-correr etapa_3 para que el"
echo "   frontend apunte a la IP correcta."
echo "=========================================="