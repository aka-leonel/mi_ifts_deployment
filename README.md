# miIFTS — Despliegue en AWS con Terraform

Migración de los scripts `etapa_1` a `etapa_4` (Bash + AWS CLI) a Terraform, para el mismo entorno: **AWS Academy Learner Lab, región `us-east-1`**.

## Qué crea

| Recurso | Equivale a |
|---|---|
| VPC, IGW, 2 subnets públicas, route table | `etapa_1_infraestructura_cloud.sh` (parte 1) |
| Security Groups (backend: 80/8000, RDS: 5432 solo desde backend) | `etapa_1` (parte 2) |
| EC2 (Ubuntu 22.04, `t3.micro`, `LabInstanceProfile`) | `etapa_1` (parte 3) |
| RDS PostgreSQL 16 (`db.t3.micro`, privada) | `etapa_1` (parte 4) |
| Bucket S3 con hosting estático + política pública | `etapa_3_frontend.sh` (parte de infraestructura) |

Lo que Terraform **no** hace (porque es despliegue de aplicación, no infraestructura) sigue en `deploy.sh`:
- Instalar Docker y levantar el backend vía SSM (`etapa_2_backend.sh`)
- Build de la PWA con `npm` y `aws s3 sync` al bucket (`etapa_3_frontend.sh`)

## Estructura

```
deploy-terraform/
├── README.md
├── deploy.sh                       # credenciales + terraform apply + deploy backend/frontend
├── destroy.sh                      # credenciales + terraform destroy
├── .gitignore
└── terraform/
    ├── provider.tf
    ├── variables.tf
    ├── outputs.tf
    ├── vpc.tf                      # reemplaza etapa_1 (red)
    ├── security_groups.tf          # reemplaza etapa_1 (SGs)
    ├── ec2.tf                      # reemplaza etapa_1 (EC2)
    ├── rds.tf                      # reemplaza etapa_1 (RDS)
    ├── s3_frontend.tf              # reemplaza parte de etapa_3
    └── terraform.tfvars.example
```

## Prerrequisitos

- Terraform >= 1.5 instalado (en CloudShell no viene por defecto — ver nota abajo)
- AWS CLI (ya viene en CloudShell)
- `npm` disponible en el entorno donde corrés `deploy.sh` (para el build del frontend)

**Instalar Terraform en CloudShell**, si no lo tenés:
```bash
curl -fsSL https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt update && sudo apt install terraform
```

## Cómo se manejan las credenciales

Learner Lab te da credenciales **temporales** (access key, secret key, session token) que expiran cada pocas horas. En vez de pegarlas en un archivo del repo, `deploy.sh` y `destroy.sh` te las piden de forma interactiva al arrancar y las exportan solo como variables de entorno de esa sesión de terminal — nunca tocan disco ni el repositorio. Ver la discusión completa de por qué se eligió así más abajo en "Notas".

## Uso

### 1. Desplegar todo

```bash
chmod +x deploy.sh destroy.sh
./deploy.sh
```

Te va a pedir que pegues el bloque de credenciales de Learner Lab (AWS Details → AWS CLI), algo así:

```
export AWS_ACCESS_KEY_ID="..."
export AWS_SECRET_ACCESS_KEY="..."
export AWS_SESSION_TOKEN="..."
```

Pegalo completo y apretá Enter en una línea vacía para continuar. A partir de ahí el script:
1. Corre `terraform init` + `terraform apply` (crea VPC, EC2, RDS, S3)
2. Espera a que el agente SSM registre la instancia
3. Instala Docker y levanta el backend en la EC2 vía SSM, corre el seed
4. Compila el frontend con `npm run build` y lo sube al bucket S3

Al final te muestra las URLs del backend y del frontend.

### 2. Volver a desplegar (re-ejecutar)

`deploy.sh` es re-ejecutable: `terraform apply` no vuelve a crear lo que ya existe, solo aplica diferencias. Si solo cambiaste código de la app (no la infraestructura), lo más rápido es correr manualmente los pasos 2 a 4 del script, o simplemente volver a correr `./deploy.sh` entero (Terraform va a detectar que la infra ya está y no hace nada ahí).

### 3. Destruir todo

```bash
./destroy.sh
```

Pide credenciales igual que `deploy.sh` y corre `terraform destroy`, que elimina exactamente los recursos que Terraform creó (VPC, EC2, RDS, S3, SGs, subnets, IGW, route table) en el orden correcto — se terminan los problemas de recursos huérfanos (como las VPCs `miifts-vpc` sobrantes) porque Terraform los tiene registrados en el `state`.

## Personalización

Copiá `terraform/terraform.tfvars.example` a `terraform/terraform.tfvars` (ya está en `.gitignore`) si querés cambiar valores por defecto: tipo de instancia, clase de RDS, password de la base, etc. También podés usar variables de entorno `TF_VAR_<nombre>` sin crear el archivo, por ejemplo:

```bash
export TF_VAR_db_password="otra-password"
```

## Notas sobre Learner Lab

- **`LabInstanceProfile`** es el instance profile fijo del lab — está hardcodeado como default de `instance_profile_name` en `variables.tf`. No se pueden crear roles IAM nuevos en este entorno.
- **El `terraform.tfstate`** queda en `terraform/` (local, gitignoreado). Como el lab se resetea, no tiene sentido un backend remoto en S3 acá — si el lab se resetea y perdés el state, simplemente corré `destroy.sh` no va a poder limpiar nada (porque el state se perdió junto con el lab) y los recursos ya no existen de todas formas.
- **La región** queda fija en `us-east-1`, igual que en los scripts originales.

## Por qué credenciales interactivas y no un archivo plantilla

Se evaluaron dos opciones:
1. Un archivo tipo `terraform.tfvars` o `credentials.txt` donde el usuario pega las credenciales a mano.
2. Un script interactivo que las pide en cada ejecución (la opción elegida).

La opción 1 se descartó por riesgo de que el archivo termine commiteado con un `git add .` (exponiendo el `session_token` en el historial), y porque genera más fricción: hay que editar el archivo cada vez que el lab expira (cada 3-4 horas). La opción interactiva mantiene las credenciales solo en variables de entorno de la sesión de terminal, nunca en disco de forma persistente ni en el repo.
