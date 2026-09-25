#!/bin/bash
# ==========================================
# Etapa 6: Reanudar el entorno pausado con etapa_5_pausar.sh
# ==========================================

export AWS_DEFAULT_REGION=us-east-1
export AWS_PAGER=""
IDS_FILE=~/miifts-ids.sh

if [ ! -f "$IDS_FILE" ]; then
  echo "❌ No encuentro $IDS_FILE. ¿Hay un despliegue pausado?"
  exit 1
fi
source "$IDS_FILE"

if [ -z "$INSTANCE_ID" ] || [ -z "$DB_INSTANCE_IDENTIFIER" ]; then
  echo "❌ Faltan INSTANCE_ID o DB_INSTANCE_IDENTIFIER en $IDS_FILE."
  exit 1
fi

echo "=== INICIANDO INSTANCIA RDS ($DB_INSTANCE_IDENTIFIER) ==="
aws rds start-db-instance --db-instance-identifier "$DB_INSTANCE_IDENTIFIER" > /dev/null
echo "Esperando a que RDS esté disponible (puede tardar varios minutos)..."
aws rds wait db-instance-available --db-instance-identifier "$DB_INSTANCE_IDENTIFIER"

DB_HOST=$(aws rds describe-db-instances \
  --db-instance-identifier "$DB_INSTANCE_IDENTIFIER" \
  --query 'DBInstances[0].Endpoint.Address' --output text)
if [ -z "$DB_HOST" ] || [ "$DB_HOST" = "None" ]; then
  echo "❌ No se pudo obtener el endpoint de RDS al reanudar."
  exit 1
fi
sed -i "/^export DB_HOST=/d" "$IDS_FILE"
echo "export DB_HOST=\"$DB_HOST\"" >> "$IDS_FILE"
echo "RDS disponible en: $DB_HOST"

echo "=== INICIANDO INSTANCIA EC2 ($INSTANCE_ID) ==="
aws ec2 start-instances --instance-ids "$INSTANCE_ID" > /dev/null
aws ec2 wait instance-running --instance-ids "$INSTANCE_ID"

PUBLIC_IP=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
sed -i "/^export PUBLIC_IP=/d" "$IDS_FILE"
echo "export PUBLIC_IP=\"$PUBLIC_IP\"" >> "$IDS_FILE"
echo "EC2 disponible en: $PUBLIC_IP (¡puede haber cambiado respecto a antes de pausar!)"

echo "=========================================="
echo "✅ Entorno reanudado."
echo "   DB_HOST y PUBLIC_IP actualizados en $IDS_FILE."
echo "   Si el backend en la EC2 tenía el .env con el DB_HOST viejo,"
echo "   o si PUBLIC_IP cambió, re-corré etapa_2 y etapa_3 para"
echo "   que backend y frontend usen los valores nuevos."
echo "=========================================="