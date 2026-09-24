#!/bin/bash
# ==========================================
# Etapa 4: Limpieza de TODOS los recursos miIFTS (por tags, no depende de ~/miifts-ids.sh)
# Solo toca lo que se llame miifts-*; nunca la VPC default.
# No usa "set -e" a propósito: si un paso falla, sigue con el resto.
# ==========================================

export AWS_DEFAULT_REGION=us-east-1
export AWS_PAGER=""

echo "=== 1. BUCKETS S3 ==="
for b in $(aws s3api list-buckets --query "Buckets[?starts_with(Name,'miifts-frontend-bucket-')].Name" --output text); do
  echo "Borrando bucket $b"
  aws s3 rb s3://$b --force
done

echo "=== 2. INSTANCIAS EC2 ==="
IDS=$(aws ec2 describe-instances \
  --filters Name=tag:Name,Values=miifts-backend Name=instance-state-name,Values=pending,running,stopping,stopped \
  --query 'Reservations[].Instances[].InstanceId' --output text)
if [ -n "$IDS" ]; then
  echo "Terminando: $IDS"
  aws ec2 terminate-instances --instance-ids $IDS > /dev/null
  aws ec2 wait instance-terminated --instance-ids $IDS
fi

echo "=== 3. RED (VPCs con tag miifts-vpc) ==="
for VPC in $(aws ec2 describe-vpcs --filters Name=tag:Name,Values=miifts-vpc --query 'Vpcs[].VpcId' --output text); do
  echo "-- $VPC"
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

echo "=== VERIFICACIÓN ==="
LEFT_BUCKETS=$(aws s3api list-buckets --query "Buckets[?starts_with(Name,'miifts-')].Name" --output text)
LEFT_VPCS=$(aws ec2 describe-vpcs --filters Name=tag:Name,Values=miifts-vpc --query 'Vpcs[].VpcId' --output text)
echo "Buckets restantes: ${LEFT_BUCKETS:-ninguno}"
echo "VPCs restantes: ${LEFT_VPCS:-ninguna}"

if [ -z "$LEFT_BUCKETS" ] && [ -z "$LEFT_VPCS" ]; then
  rm -f ~/miifts-ids.sh
  echo "✅ Limpieza completa"
else
  echo "⚠️ Quedaron recursos. Vuelve a correr este script o revisa los mensajes de error de arriba."
  exit 1
fi