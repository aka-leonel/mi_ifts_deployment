# Guía de Despliegue Automatizado: PWA miIFTS en AWS Academy (Learner Lab)

Esta guía detalla el paso a paso y los comandos utilizados para desplegar la arquitectura completa (Frontend en S3, Backend con FastAPI y Docker en EC2, y Base de Datos PostgreSQL) utilizando **AWS CloudShell** para evitar inconvenientes con conexiones locales.

---

## Prerrequisitos
* Acceso activo al **AWS Academy Learner Lab** con la región configurada en **Norte de Virginia (us-east-1)**[cite: 1].
* Consola de **AWS CloudShell** abierta[cite: 1].

---

## Paso 1: Despliegue de la Infraestructura de Red y Servidor (EC2)

Copia este script completo y pégalo en tu **AWS CloudShell**. Automatizará la creación de la VPC, subred pública, internet gateway, tabla de ruteo, security groups y el lanzamiento de la instancia EC2 con Ubuntu[cite: 1].

```bash
#!/bin/bash
set -e

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
aws ec2 attach-internet-gateway --internet-gateway-id $IGW_ID --vpc-id$VPC_ID

# Subnet Pública
PUB_SUBNET=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block 10.0.1.0/24 --availability-zone ${REGION}a \
 --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=$TAG-public}]" --query 'Subnet.SubnetId' --output text)
aws ec2 modify-subnet-attribute --subnet-id $PUB_SUBNET --map-public-ip-on-launch

# Route Table Pública
RT_PUB=$(aws ec2 create-route-table --vpc-id$VPC_ID --query 'RouteTable.RouteTableId' --output text)
aws ec2 create-route --route-table-id $RT_PUB --destination-cidr-block 0.0.0.0/0 --gateway-id $IGW_ID
aws ec2 associate-route-table --route-table-id $RT_PUB --subnet-id$PUB_SUBNET

echo "=== 2. CREANDO SECURITY GROUPS ==="
SG_ID=$(aws ec2 create-security-group --group-name "$TAG-sg-fixed" \
 --description "SG para miIFTS Backend" --vpc-id $VPC_ID --query 'GroupId' --output text)

aws ec2 authorize-security-group-ingress --group-id $SG_ID --protocol tcp --port 22 --cidr 0.0.0.0/0
aws ec2 authorize-security-group-ingress --group-id $SG_ID --protocol tcp --port 80 --cidr 0.0.0.0/0
aws ec2 authorize-security-group-ingress --group-id $SG_ID --protocol tcp --port 8000 --cidr 0.0.0.0/0

echo "=== 3. LANZANDO INSTANCIA EC2 ==="
# Búsqueda directa de AMI de Ubuntu 22.04 LTS compatible con la región
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

PUBLIC_IP=$(aws ec2 describe-instances --instance-ids$INSTANCE_ID --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)

# Guardar variables en un archivo de sesión local para reusar
cat > ~/miifts-ids.sh <<EOF ! " "ID "INFRAESTRUCTURA "IP "backend-ifts" # ## $INSTANCE_ID $INSTANCE_ID" $PUBLIC_IP" 'EOF' (FastAPI (SSM)** (rama **AWS + --- --document-name --parameters --target -b -d 1. 2. 2: << AMI_ID="$AMI_ID" AWS-StartInteractiveCommand AWS_DEFAULT_REGION="us-east-1" Backend Backend: CON CREADA Configuración Conéctate Crear Despliegue Docker) EC2 EC2, EOF IGW_ID="$IGW_ID" INSTANCE_ID="$INSTANCE_ID" Instancia: Manager PUBLIC_IP="$PUBLIC_IP" PUB_SUBNET="$PUB_SUBNET" Paso Pública REGION="us-east-1" RT_PUB="$RT_PUB" SG_ID="$SG_ID" Systems TAG="$TAG" Una VPC_ID="$VPC_ID" [ ]; `.env` ``` ```bash `dev`), `ubuntu`: a archivo aws backend backend-ifts cat cd clona clone command="sudo su - ubuntu" con configuración contenedores: crea creada de del dentro dev echo el entorno estándar export fi git [https://github.com/aka-leonel/backend-ifts.git](https://github.com/aka-leonel/backend-ifts.git) if instancia la levanta los origin pull recién repositorio source ssm start-session terminal then usuario utilizando vez y ~ ~/miifts-ids.sh ÉXITO:"> .env
   DATABASE_URL=postgresql://postgres:postgres@db:5432/miifts
   POSTGRES_USER=postgres
   POSTGRES_PASSWORD=postgres
   POSTGRES_DB=miifts
   CORS_ORIGINS=*
   EOF

   # Construir y levantar servicios con Docker Compose
   sudo docker compose up -d --build
   
   
----------------------
   
   
1 Ejecuta el script de inicialización (seed.py) para poblar la base de datos:
docker exec -it backend-ifts-api-1 python seed.py

2 Sal de la sesión de la EC2 para volver a CloudShell:
exit


----------------------

Paso 3: Despliegue del Frontend (React + Vite en AWS S3)

1 En tu terminal de CloudShell, clona el repositorio del frontend y configura la IP del backend:

source ~/miifts-ids.sh
cd ~
if [ ! -d "frontend-miifts" ]; then 
  git clone -b dev [https://github.com/aka-leonel/frontend-miifts.git](https://github.com/aka-leonel/frontend-miifts.git)
fi
cd frontend-miifts
git pull origin dev

# Apuntar la aplicación al backend desplegado
echo "VITE_API_URL=http://$PUBLIC_IP:8000" > .env




2 Instala dependencias y compila el proyecto:

npm install
npm run build



3 Crea el bucket de S3, otorga los permisos públicos correspondientes y sube los archivos compilados:

BUCKET_NAME="$TAG-frontend-bucket-$(date +%s)"

# Crear bucket
aws s3api create-bucket --bucket $BUCKET_NAME --region us-east-1

# Desactivar restricciones de acceso público
aws s3api put-public-access-block --bucket $BUCKET_NAME \
  --public-access-block-configuration "BlockPublicAcls=false,IgnorePublicAcls=false,BlockPublicPolicy=false,RestrictPublicBuckets=false"

# Aplicar política de lectura pública
aws s3api put-bucket-policy --bucket $BUCKET_NAME --policy "{
  \"Version\": \"2012-10-17\",
  \"Statement\": [
    {
      \"Sid\": \"PublicReadGetObject\",
      \"Effect\": \"Allow\",
      \"Principal\": \"*\",
      \"Action\": \"s3:GetObject\",
      \"Resource\": \"arn:aws:s3:::$BUCKET_NAME/*\"
    }
  ]
}"

# Habilitar sitio web estático y subir los archivos de la build
aws s3 website s3://$BUCKET_NAME/ --index-document index.html --error-document index.html
aws s3 sync dist/ s3://$BUCKET_NAME/

echo "=================================================="
echo "URL del sitio web estático (PWA):"
echo "http://$BUCKET_NAME.s3-website-us-east-1.amazonaws.com"
echo "=================================================="









