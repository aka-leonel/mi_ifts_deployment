#!/bin/bash
# ==========================================
# Etapa 4: Limpieza de TODOS los recursos miIFTS (incluyendo RDS)
# ==========================================

export AWS_DEFAULT_REGION=us-east-1
export AWS_PAGER=""
TAG="miifts"

echo "=== 1. ELIMINANDO INSTANCIA RDS ==="
DB_INSTANCE_IDENTIFIER="$TAG-db"
if aws rds describe-db-instances --db-instance-identifier "$DB_INSTANCE_IDENTIFIER" 2>/dev/null \vert{} grep -q "$DB_INSTANCE_IDENTIFIER"; then
  echo "Eliminando instancia RDS $DB_INSTANCE_IDENTIFIER (esto puede tardar unos minutos)..."
  aws rds delete-db-instance --db-instance-identifier "$DB_INSTANCE_IDENTIFIER" --skip-final-snapshot --delete-automated-backups > /dev/null
  aws rds wait db-instance-deleted --db-instance-identifier "$DB_INSTANCE_IDENTIFIER"
  echo "RDS eliminada."
fi

echo "=== 2. BUCKETS S3 ==="
for b in $(aws s3api list-buckets --query "Buckets[?starts_with(Name,'miifts-frontend-bucket-')].Name" --output text); do
  echo "Borrando bucket $b"
  aws s3 rb s3://$b --force
done

echo "=== 3. INSTANCIAS EC2 ==="
IDS=$(aws ec2 describe-instances \
  --filters Name=tag:Name,Values=miifts-backend Name=instance-state-name,Values=pending,running,stopping,stopped \
  --query 'Reservations[].Instances[].InstanceId' --output text)
if [ -n "$IDS" ]; then
  echo "Terminando: $IDS"
  aws ec2 terminate-instances --instance-ids $IDS > /dev/null
  aws ec2 wait instance-terminated --instance-ids $IDS
fi

echo "=== 4. RED Y DB SUBNET GROUPS ==="
# Borrar DB Subnet Group antes de eliminar la VPC/Subredes
if aws rds describe-db-subnet-groups --db-subnet-group-name "$TAG-db-subnet-group" 2>/dev/null \vert{} grep -q "$TAG-db-subnet-group"; then
  aws rds delete-db-subnet-group --db-subnet-group-name "$TAG-db-subnet-group"
fi

for VPC in $(aws ec2 describe-vpcs --filters Name=tag:Name,Values=miifts-vpc --query 'Vpcs[].VpcId' --output text); do
  echo "-- Limpiando VPC $VPC"
  for sg in $(aws ec2 describe-security-groups --filters Name=vpc-id,Values=$VPC \
      --query 'SecurityGroups[?GroupName!=`default`].GroupId' --output text); do
    for i in 1 2 3 4 5 6; do
      aws ec2 delete-security-group --group-id $sg 2>/dev/null && break
      sleep 10
    done
  done
  for s in $(aws ec2 describe-subnets --filters Name=vpc-id,Values=$VPC --query 'Subnets[].SubnetId' --output text); do
    aws ec2 delete-subnet --subnet-id $s
  done
  for rt in $(aws ec2 describe-route-tables --filters Name=vpc-id,Values=$VPC \
      --query 'RouteTables[?length(Associations[?Main==`true`])==`0`].RouteTableId' --output text); do
    aws ec2 delete-route-table --route-table-id $rt
  done
  for igw in $(aws ec2 describe-internet-gateways --filters Name=attachment.vpc-id,Values=$VPC \
      --query 'InternetGateways[].InternetGatewayId' --output text); do
    aws ec2 detach-internet-gateway --internet-gateway-id $igw --vpc-id $VPC
    aws ec2 delete-internet-gateway --internet-gateway-id $igw
  done
  aws ec2 delete-vpc --vpc-id $VPC && echo "   VPC $VPC eliminada"
done

rm -f ~/miifts-ids.sh
echo "✅ Limpieza completa de arquitectura desacoplada"