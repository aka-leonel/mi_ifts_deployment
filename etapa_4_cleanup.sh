#!/bin/bash
set -e

# Cargar las variables guardadas durante la creación
if [ -f ~/miifts-ids.sh ]; then
  source ~/miifts-ids.sh
else
  echo "⚠️ No se encontró el archivo miifts-ids.sh. Asegúrate de tener las variables o configúralas manualmente."
fi

export AWS_DEFAULT_REGION=us-east-1

echo "=== 1. ELIMINANDO BUCKET DE S3 (FRONTEND) ==="
if [ ! -z "$BUCKET_NAME" ]; then
  echo "Vaciando y eliminando bucket: $BUCKET_NAME"
  # --force vacía y borra el bucket de S3 de manera directa y segura
  aws s3 rb s3://$BUCKET_NAME --force || echo "No se pudo borrar el bucket automáticamente, revísalo en la consola."
else
  echo "No se encontró la variable BUCKET_NAME. Si creaste otro bucket, bórralo manualmente desde la consola."
fi

echo "=== 2. TERMINANDO INSTANCIA EC2 ==="
if [ ! -z "$INSTANCE_ID" ]; then
  echo "Terminando instancia EC2: $INSTANCE_ID"
  aws ec2 terminate-instances --instance-ids $INSTANCE_ID
  echo "Esperando a que la instancia se detenga por completo..."
  aws ec2 wait instance-terminated --instance-ids $INSTANCE_ID
fi

echo "=== 3. ELIMINANDO SECURITY GROUP ==="
if [ ! -z "$SG_ID" ]; then
  echo "Eliminando Security Group: $SG_ID"
  # Damos una pausa prudente para que AWS libere el ENI (Network Interface) de la EC2
  sleep 10
  aws ec2 delete-security-group --group-id $SG_ID || echo "No se pudo borrar todavía, reintenta en un momento."
fi

echo "=== 4. DESVINCULANDO Y ELIMINANDO RED (VPC, SUBNET, IGW, ROUTE TABLE) ==="
if [ ! -z "$PUB_SUBNET" ] && [ ! -z "$RT_PUB" ]; then
  # Buscar correctamente el ID de asociación de la tabla de ruteo
  ASSOC_ID=$(aws ec2 describe-route-tables --route-table-ids $RT_PUB --query "RouteTables[0].Associations[?SubnetId=='$PUB_SUBNET'].RouteTableAssociationId" --output text)
  if [ ! -z "$ASSOC_ID" ] && [ "$ASSOC_ID" != "None" ]; then
    echo "Desasociando tabla de ruteo..."
    aws ec2 disassociate-route-table --association-id $ASSOC_ID
  fi
  echo "Eliminando tabla de ruteo y subred..."
  aws ec2 delete-route-table --route-table-id $RT_PUB
  aws ec2 delete-subnet --subnet-id $PUB_SUBNET
fi

if [ ! -z "$VPC_ID" ] && [ ! -z "$IGW_ID" ]; then
  echo "Desvinculando Internet Gateway y eliminando VPC..."
  aws ec2 detach-internet-gateway --internet-gateway-id $IGW_ID --vpc-id $VPC_ID
  aws ec2 delete-internet-gateway --internet-gateway-id $IGW_ID
  aws ec2 delete-vpc --vpc-id $VPC_ID
fi

# Limpiar archivo de sesión
rm -f ~/miifts-ids.sh

echo "=================================================="
echo "✅ ¡LIMPIEZA COMPLETADA! Todos los recursos fueron eliminados."
echo "=================================================="