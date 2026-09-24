#!/bin/bash
set -e

# ==========================================
# SCRIPT DE DESPLIEGUE AUTOMATIZADO - miIFTS
# Etapa 1: Infraestructura (VPC, IGW, Subnet, SG, EC2)
# Entorno: AWS Academy Learner Lab (us-east-1)
# ==========================================

export AWS_DEFAULT_REGION=us-east-1
REGION="us-east-1"
TAG="miifts"
IDS_FILE=~/miifts-ids.sh

# No permitir un segundo despliegue encima de uno sin limpiar
if [ -f "$IDS_FILE" ]; then
  echo "❌ Ya existe $IDS_FILE: hay un despliegue sin limpiar."
  echo "   Ejecuta primero: bash etapa_4_cleanup.sh"
  exit 1
fi

# Si algo falla, avisar cómo limpiar lo que haya quedado creado
trap 'echo "❌ La etapa 1 falló. Ejecuta etapa_4_cleanup.sh para eliminar lo que se haya creado."' ERR

# Guarda cada variable apenas se crea el recurso (así la limpieza siempre puede encontrarlo)
save() { echo "export $1=\"${!1}\"" >> "$IDS_FILE"; }
: > "$IDS_FILE"
save TAG

echo "=== 1. CREANDO INFRAESTRUCTURA DE RED (VPC) ==="

# VPC
VPC_ID=$(aws ec2 create-vpc --cidr-block 10.0.0.0/16 \
 --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=$TAG-vpc}]" \
 --query 'Vpc.VpcId' --output text)
save VPC_ID

aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-hostnames
aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-support

# Internet Gateway
IGW_ID=$(aws ec2 create-internet-gateway \
 --tag-specifications "ResourceType=internet-gateway,Tags=[{Key=Name,Value=$TAG-igw}]" \
 --query 'InternetGateway.InternetGatewayId' --output text)
save IGW_ID
aws ec2 attach-internet-gateway --internet-gateway-id $IGW_ID --vpc-id $VPC_ID

# Subnet Pública
PUB_SUBNET=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block 10.0.1.0/24 --availability-zone ${REGION}a \
 --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=$TAG-public}]" \
 --query 'Subnet.SubnetId' --output text)
save PUB_SUBNET
aws ec2 modify-subnet-attribute --subnet-id $PUB_SUBNET --map-public-ip-on-launch

# Route Table Pública
RT_PUB=$(aws ec2 create-route-table --vpc-id $VPC_ID \
 --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=$TAG-rt-public}]" \
 --query 'RouteTable.RouteTableId' --output text)
save RT_PUB
aws ec2 create-route --route-table-id $RT_PUB --destination-cidr-block 0.0.0.0/0 --gateway-id $IGW_ID > /dev/null
aws ec2 associate-route-table --route-table-id $RT_PUB --subnet-id $PUB_SUBNET > /dev/null

echo "=== 2. CREANDO SECURITY GROUP ==="
SG_ID=$(aws ec2 create-security-group --group-name "$TAG-sg-fixed" \
 --description "SG para miIFTS Backend" --vpc-id $VPC_ID \
 --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=$TAG-sg}]" \
 --query 'GroupId' --output text)
save SG_ID

# El acceso a la instancia se hace por SSM, por eso no se abre el puerto 22
aws ec2 authorize-security-group-ingress --group-id $SG_ID --protocol tcp --port 80 --cidr 0.0.0.0/0 > /dev/null
aws ec2 authorize-security-group-ingress --group-id $SG_ID --protocol tcp --port 8000 --cidr 0.0.0.0/0 > /dev/null

echo "=== 3. LANZANDO INSTANCIA EC2 ==="
# AMI oficial de Ubuntu 22.04 LTS (Canonical)
AMI_ID=$(aws ec2 describe-images \
 --owners 099720109477 \
 --filters "Name=name,Values=ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*" "Name=state,Values=available" \
 --query "sort_by(Images, &CreationDate)[-1].ImageId" --output text)

if [ -z "$AMI_ID" ] || [ "$AMI_ID" = "None" ]; then
  echo "❌ No se encontró la AMI de Ubuntu 22.04"
  exit 1
fi

INSTANCE_ID=$(aws ec2 run-instances \
 --image-id $AMI_ID \
 --instance-type t3.micro \
 --subnet-id $PUB_SUBNET \
 --security-group-ids $SG_ID \
 --iam-instance-profile Name=LabInstanceProfile \
 --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$TAG-backend}]" \
 --query 'Instances[0].InstanceId' --output text)
save INSTANCE_ID

echo "Esperando a que la instancia EC2 esté activa..."
aws ec2 wait instance-running --instance-ids $INSTANCE_ID

# IP pública
PUBLIC_IP=$(aws ec2 describe-instances --instance-ids $INSTANCE_ID \
 --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
save PUBLIC_IP

trap - ERR

echo "=========================================="
echo "INFRAESTRUCTURA CREADA CON ÉXITO:"
echo "ID de Instancia: $INSTANCE_ID"
echo "IP Pública del Backend: $PUBLIC_IP"
echo "Variables guardadas en $IDS_FILE"
echo "=========================================="