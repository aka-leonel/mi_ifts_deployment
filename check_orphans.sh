#!/bin/bash
# ==========================================
# check_orphans.sh
# Lista recursos activos/potencialmente huérfanos en una UNICA REGION (us-east-1)
# (pensado para AWS Academy Learner Lab, donde solo suele estar
#  habilitada esa región y no hay que preocuparse por otras.)
# ==========================================

export AWS_PAGER=""
REGION="${1:-us-east-1}"
export AWS_DEFAULT_REGION="$REGION"

sep() { echo "-------------------------------------------------------"; }

echo "=========================================================="
echo " CHEQUEO DE RECURSOS - Región: $REGION"
echo "=========================================================="

echo
echo "### EC2 - Instancias (running/stopped/pending/stopping) ###"
sep
aws ec2 describe-instances \
  --filters "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query 'Reservations[].Instances[].{ID:InstanceId,Estado:State.Name,Tipo:InstanceType,Nombre:Tags[?Key==`Name`]|[0].Value,IP:PublicIpAddress,Lanzada:LaunchTime}' \
  --output table

echo
echo "### EC2 - Elastic IPs (si no están asociadas, cobran igual) ###"
sep
aws ec2 describe-addresses \
  --query 'Addresses[].{IP:PublicIp,AsociadaA:InstanceId,AllocationId:AllocationId}' \
  --output table

echo
echo "### EC2 - Volúmenes EBS sin adjuntar ###"
sep
aws ec2 describe-volumes \
  --filters "Name=status,Values=available" \
  --query 'Volumes[].{ID:VolumeId,SizeGB:Size,Tipo:VolumeType,Estado:State}' \
  --output table

echo
echo "### VPC - Todas las VPCs (se marca cuál es la default de la región) ###"
sep
aws ec2 describe-vpcs \
  --query 'Vpcs[].{ID:VpcId,CIDR:CidrBlock,Nombre:Tags[?Key==`Name`]|[0].Value,Default:IsDefault}' \
  --output table

DEFAULT_VPC=$(aws ec2 describe-vpcs --filters "Name=isDefault,Values=true" \
  --query 'Vpcs[0].VpcId' --output text)
if [ "$DEFAULT_VPC" != "None" ] && [ -n "$DEFAULT_VPC" ]; then
  echo "ℹ️  $DEFAULT_VPC es la VPC DEFAULT de la región — la crea AWS automáticamente, no la borres."
fi

echo
echo "### VPC - Internet Gateways ###"
sep
aws ec2 describe-internet-gateways \
  --query 'InternetGateways[].{ID:InternetGatewayId,VPC:Attachments[0].VpcId,Nombre:Tags[?Key==`Name`]|[0].Value}' \
  --output table

IGW_VPCS=$(aws ec2 describe-internet-gateways --query 'InternetGateways[].Attachments[0].VpcId' --output text)
for vpc in $IGW_VPCS; do
  [ "$vpc" = "None" ] && continue
  IS_DEFAULT=$(aws ec2 describe-vpcs --vpc-ids "$vpc" --query 'Vpcs[0].IsDefault' --output text 2>/dev/null)
  if [ "$IS_DEFAULT" = "True" ]; then
    echo "ℹ️  El IGW de la VPC $vpc pertenece a la VPC DEFAULT de la región — es normal, no hace falta borrarlo."
  fi
done

echo
echo "### VPC - NAT Gateways (cobran por hora aunque no se usen) ###"
sep
aws ec2 describe-nat-gateways \
  --filter "Name=state,Values=available,pending" \
  --query 'NatGateways[].{ID:NatGatewayId,VPC:VpcId,Estado:State}' \
  --output table

echo
echo "### EC2 - Security Groups no default ###"
sep
aws ec2 describe-security-groups \
  --query 'SecurityGroups[?GroupName!=`default`].{ID:GroupId,Nombre:GroupName,VPC:VpcId}' \
  --output table

echo
echo "### RDS - Instancias de base de datos ###"
sep
aws rds describe-db-instances \
  --query 'DBInstances[].{ID:DBInstanceIdentifier,Motor:Engine,Estado:DBInstanceStatus,Endpoint:Endpoint.Address}' \
  --output table

echo
echo "### RDS - DB Subnet Groups ###"
sep
aws rds describe-db-subnet-groups \
  --query 'DBSubnetGroups[].{Nombre:DBSubnetGroupName,VPC:VpcId,Estado:SubnetGroupStatus}' \
  --output table

echo
echo "### RDS - Snapshots manuales (quedan y cobran storage) ###"
sep
aws rds describe-db-snapshots \
  --snapshot-type manual \
  --query 'DBSnapshots[].{ID:DBSnapshotIdentifier,DBOrigen:DBInstanceIdentifier,Estado:Status}' \
  --output table

echo
echo "### ELB - Load Balancers (ALB/NLB) ###"
sep
aws elbv2 describe-load-balancers \
  --query 'LoadBalancers[].{Nombre:LoadBalancerName,Tipo:Type,Estado:State.Code}' \
  --output table

echo
echo "### S3 - Buckets (namespace global, no depende de la región) ###"
sep
aws s3api list-buckets \
  --query 'Buckets[].{Nombre:Name,Creado:CreationDate}' \
  --output table

echo
echo "=========================================================="
echo " Fin del chequeo. Si algo de esto no lo reconocés como"
echo " parte de un despliegue vigente, probablemente sea un"
echo " recurso huérfano a limpiar manualmente."
echo "=========================================================="