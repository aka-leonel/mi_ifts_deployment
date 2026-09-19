#!/bin/bash
set -e

# ==========================================
# SCRIPT DE DESPLIEGUE AUTOMATIZADO - miIFTS
# Entorno: AWS Academy Learner Lab (us-east-1)
# ==========================================

export AWS_DEFAULT_REGION=us-east-1
REGION="us-east-1"
TAG="miifts"

echo "=== 1. CREANDO INFRAESTRUCTURA DE RED (VPC) ==="

# Crear VPC
VPC_ID=$(aws ec2 create-vpc --cidr-block 10.0.0.0/16 \
 --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=$TAG-vpc}]" \
 --query 'Vpc.VpcId' --output text)

aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-hostnames
aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-support

# Internet Gateway
IGW_ID=$(aws ec2 create-internet-gateway \
 --tag-specifications "ResourceType=internet-gateway,Tags=[{Key=Name,Value=$TAG-igw}]" \
 --query 'InternetGateway.InternetGatewayId' --output text)
aws ec2 attach-internet-gateway --internet-gateway-id $IGW_ID --vpc-id $VPC_ID

# Subnet Pública
PUB_SUBNET=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block 10.0.1.0/24 --availability-zone ${REGION}a \
 --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=$TAG-public}]" --query 'Subnet.SubnetId' --output text)
aws ec2 modify-subnet-attribute --subnet-id $PUB_SUBNET --map-public-ip-on-launch

# Route Table Pública
RT_PUB=$(aws ec2 create-route-table --vpc-id $VPC_ID --query 'RouteTable.RouteTableId' --output text)
aws ec2 create-route --route-table-id $RT_PUB --destination-cidr-block 0.0.0.0/0 --gateway-id $IGW_ID
aws ec2 associate-route-table --route-table-id $RT_PUB --subnet-id $PUB_SUBNET

echo "=== 2. CREANDO SECURITY GROUPS ==="
SG_ID=$(aws ec2 create-security-group --group-name "$TAG-sg-fixed" \
 --description "SG para miIFTS Backend" --vpc-id $VPC_ID --query 'GroupId' --output text)

aws ec2 authorize-security-group-ingress --group-id $SG_ID --protocol tcp --port 22 --cidr 0.0.0.0/0
aws ec2 authorize-security-group-ingress --group-id $SG_ID --protocol tcp --port 80 --cidr 0.0.0.0/0
aws ec2 authorize-security-group-ingress --group-id $SG_ID --protocol tcp --port 8000 --cidr 0.0.0.0/0

echo "=== 3. LANZANDO INSTANCIA EC2 ==="
# Búsqueda directa de la AMI oficial de Ubuntu 22.04 LTS en la región
AMI_ID=$(aws ec2 describe-images \
 --owners 099720109477 \
 --filters "Name=name,Values=ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*" "Name=state,Values=available" \
 --query "sort_by(Images, &CreationDate)[-1].ImageId" --output text)

INSTANCE_ID=$(aws ec2 run-instances \
 --image-id $AMI_ID \
 --instance-type t3.micro \
 --subnet-id $PUB_SUBNET \
 --security-group-ids $SG_ID \
 --iam-instance-profile Name=LabInstanceProfile \
 --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$TAG-backend}]" \
 --query 'Instances[0].InstanceId' --output text)

echo "Esperando a que la instancia EC2 esté activa..."
aws ec2 wait instance-running --instance-ids $INSTANCE_ID

# Obtener IP Pública
PUBLIC_IP=$(aws ec2 describe-instances --instance-ids $INSTANCE_ID --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)

# Guardar las variables en un archivo de sesión para reutilizarlas fácilmente
cat > ~/miifts-ids.sh <<EOF
export TAG="$TAG"
export VPC_ID="$VPC_ID"
export IGW_ID="$IGW_ID"
export PUB_SUBNET="$PUB_SUBNET"
export RT_PUB="$RT_PUB"
export SG_ID="$SG_ID"
export INSTANCE_ID="$INSTANCE_ID"
export PUBLIC_IP="$PUBLIC_IP"
EOF

echo "=========================================="
echo "INFRAESTRUCTURA CREADA CON ÉXITO:"
echo "ID de Instancia: $INSTANCE_ID"
echo "IP Pública del Backend: $PUBLIC_IP"
echo "Variables guardadas en ~/miifts-ids.sh"
echo "=========================================="