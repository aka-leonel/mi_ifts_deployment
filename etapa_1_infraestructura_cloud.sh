#!/bin/bash
set -e

# ==========================================
# SCRIPT DE DESPLIEGUE AUTOMATIZADO - miIFTS
# Etapa 1: Infraestructura (VPC, IGW, Subnets, SGs, RDS, EC2)
# Entorno: AWS Academy Learner Lab (us-east-1)
# ==========================================

export AWS_DEFAULT_REGION=us-east-1
REGION="us-east-1"
TAG="miifts"
IDS_FILE=~/miifts-ids.sh

if [ -f "$IDS_FILE" ]; then
  echo "❌ Ya existe $IDS_FILE: hay un despliegue sin limpiar."
  echo "   Ejecuta primero: bash etapa_4_cleanup.sh"
  exit 1
fi

trap 'echo "❌ La etapa 1 falló. Ejecuta etapa_4_cleanup.sh para eliminar lo que se haya creado."' ERR

save() { echo "export $1=\"${!1}\"" >> "$IDS_FILE"; }
: > "$IDS_FILE"
save TAG

echo "=== 1. CREANDO INFRAESTRUCTURA DE RED (VPC) ==="

VPC_ID=$(aws ec2 create-vpc --cidr-block 10.0.0.0/16 \
 --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=$TAG-vpc}]" \
 --query 'Vpc.VpcId' --output text)
save VPC_ID

aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-hostnames
aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-support

IGW_ID=$(aws ec2 create-internet-gateway \
 --tag-specifications "ResourceType=internet-gateway,Tags=[{Key=Name,Value=$TAG-igw}]" \
 --query 'InternetGateway.InternetGatewayId' --output text)
save IGW_ID
aws ec2 attach-internet-gateway --internet-gateway-id $IGW_ID --vpc-id $VPC_ID

# Subnet Pública 1 (para la EC2)
PUB_SUBNET_1=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block 10.0.1.0/24 --availability-zone ${REGION}a \
 --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=$TAG-public-1}]" \
 --query 'Subnet.SubnetId' --output text)
save PUB_SUBNET_1
aws ec2 modify-subnet-attribute --subnet-id $PUB_SUBNET_1 --map-public-ip-on-launch

# Subnet Pública 2 (necesaria para RDS Multi-AZ / Subnet Group)
PUB_SUBNET_2=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block 10.0.2.0/24 --availability-zone ${REGION}b \
 --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=$TAG-public-2}]" \
 --query 'Subnet.SubnetId' --output text)
save PUB_SUBNET_2
aws ec2 modify-subnet-attribute --subnet-id $PUB_SUBNET_2 --map-public-ip-on-launch

RT_PUB=$(aws ec2 create-route-table --vpc-id $VPC_ID \
 --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=$TAG-rt-public}]" \
 --query 'RouteTable.RouteTableId' --output text)
save RT_PUB
aws ec2 create-route --route-table-id $RT_PUB --destination-cidr-block 0.0.0.0/0 --gateway-id $IGW_ID > /dev/null
aws ec2 associate-route-table --route-table-id $RT_PUB --subnet-id $PUB_SUBNET_1 > /dev/null
aws ec2 associate-route-table --route-table-id $RT_PUB --subnet-id $PUB_SUBNET_2 > /dev/null

echo "=== 2. CREANDO SECURITY GROUPS ==="
# SG para la EC2 (Backend)
SG_EC2_ID=$(aws ec2 create-security-group --group-name "$TAG-sg-backend" \
 --description "SG para miIFTS Backend EC2" --vpc-id $VPC_ID \
 --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=$TAG-sg-backend}]" \
 --query 'GroupId' --output text)
save SG_EC2_ID

aws ec2 authorize-security-group-ingress --group-id $SG_EC2_ID --protocol tcp --port 80 --cidr 0.0.0.0/0 > /dev/null
aws ec2 authorize-security-group-ingress --group-id $SG_EC2_ID --protocol tcp --port 8000 --cidr 0.0.0.0/0 > /dev/null

# SG para RDS (Base de datos)
SG_RDS_ID=$(aws ec2 create-security-group --group-name "$TAG-sg-rds" \
 --description "SG para miIFTS Database RDS" --vpc-id $VPC_ID \
 --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=$TAG-sg-rds}]" \
 --query 'GroupId' --output text)
save SG_RDS_ID

# Permitir tráfico PostgreSQL (5432) exclusivamente desde la EC2 del backend
aws ec2 authorize-security-group-ingress --group-id $SG_RDS_ID --protocol tcp --port 5432 --source-group $SG_EC2_ID > /dev/null

echo "=== 3. CREANDO INSTANCIA EC2 ==="
AMI_ID=$(aws ec2 describe-images \
 --owners 099720109477 \
 --filters "Name=name,Values=ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*" "Name=state,Values=available" \
 --query "sort_by(Images, &CreationDate)[-1].ImageId" --output text)

INSTANCE_ID=$(aws ec2 run-instances \
 --image-id $AMI_ID \
 --instance-type t3.micro \
 --subnet-id $PUB_SUBNET_1 \
 --security-group-ids $SG_EC2_ID \
 --iam-instance-profile Name=LabInstanceProfile \
 --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$TAG-backend}]" \
 --query 'Instances[0].InstanceId' --output text)
save INSTANCE_ID

echo "Esperando a que la instancia EC2 esté activa..."
aws ec2 wait instance-running --instance-ids $INSTANCE_ID

PUBLIC_IP=$(aws ec2 describe-instances --instance-ids $INSTANCE_ID \
 --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
save PUBLIC_IP

echo "=== 4. CREANDO AMAZON RDS (POSTGRESQL) ==="
# Crear DB Subnet Group requerido por RDS
aws rds create-db-subnet-group \
 --db-subnet-group-name "$TAG-db-subnet-group" \
 --db-subnet-group-description "Subnet group para miIFTS RDS" \
 --subnet-ids "$PUB_SUBNET_1" "$PUB_SUBNET_2" > /dev/null

DB_INSTANCE_IDENTIFIER="$TAG-db"
save DB_INSTANCE_IDENTIFIER

aws rds create-db-instance \
 --db-instance-identifier $DB_INSTANCE_IDENTIFIER \
 --db-instance-class db.t3.micro \
 --engine postgres \
 --engine-version 16 \
 --master-username postgres \
 --master-user-password postgrespassword \
 --allocated-storage 20 \
 --db-subnet-group-name "$TAG-db-subnet-group" \
 --vpc-security-group-ids "$SG_RDS_ID" \
 --no-publicly-accessible \
 --no-multi-az > /dev/null

echo "Esperando a que RDS esté disponible (esto puede tomar varios minutos)..."
aws rds wait db-instance-available --db-instance-identifier $DB_INSTANCE_IDENTIFIER

# Obtener el Endpoint de la Base de Datos
DB_HOST=$(aws rds describe-db-instances \
 --db-instance-identifier $DB_INSTANCE_IDENTIFIER \
 --query 'DBInstances[0].Endpoint.Address' --output text)

if [ -z "$DB_HOST" ] || [ "$DB_HOST" = "None" ]; then
  echo "❌ No se pudo obtener el endpoint de RDS."
  exit 1
fi
save DB_HOST

trap - ERR

echo "=========================================="
echo "INFRAESTRUCTURA CREADA CON ÉXITO:"
echo "ID de Instancia EC2: $INSTANCE_ID"
echo "IP Pública del Backend: $PUBLIC_IP"
echo "RDS Endpoint: $DB_HOST"
echo "Variables guardadas en $IDS_FILE"
echo "=========================================="