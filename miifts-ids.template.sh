#!/bin/bash
# ====================================================================
# Plantilla de variables de entorno para el despliegue de MIIFTS
# Instrucciones: 
# 1. Copia este archivo como 'miifts-ids.sh' (este último está en .gitignore)
# 2. Reemplaza los valores con los identificadores reales generados en tu AWS
# ====================================================================

export TAG="miifts"
export VPC_ID="vpc-xxxxxxxxx"
export IGW_ID="igw-xxxxxxxxx"
export PUB_SUBNET="subnet-xxxxxxxxx"
export RT_PUB="rtb-xxxxxxxxx"
export SG_ID="sg-xxxxxxxxx"
export INSTANCE_ID="i-xxxxxxxxx"
export PUBLIC_IP="x.x.x.x"