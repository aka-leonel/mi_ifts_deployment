variable "aws_region" {
  description = "Región de AWS donde se despliega miIFTS"
  type        = string
  default     = "us-east-1"
}

variable "tag_name" {
  description = "Prefijo usado para nombrar todos los recursos (equivalente a $TAG en los scripts originales)"
  type        = string
  default     = "miifts"
}

variable "instance_type" {
  description = "Tipo de instancia EC2 para el backend"
  type        = string
  default     = "t3.micro"
}

variable "instance_profile_name" {
  description = "Nombre del IAM Instance Profile fijo del Learner Lab (no se pueden crear roles nuevos)"
  type        = string
  default     = "LabInstanceProfile"
}

variable "db_instance_class" {
  description = "Clase de instancia para RDS"
  type        = string
  default     = "db.t3.micro"
}

variable "db_engine_version" {
  description = "Versión de PostgreSQL"
  type        = string
  default     = "16"
}

variable "db_allocated_storage" {
  description = "Almacenamiento (GB) para RDS"
  type        = number
  default     = 20
}

variable "db_name" {
  description = "Nombre de la base de datos usada en la connection string (la crea el seed/migraciones, no RDS)"
  type        = string
  default     = "miifts"
}

variable "db_username" {
  description = "Usuario master de la base de datos"
  type        = string
  default     = "postgres"
}

variable "db_password" {
  description = "Password master de la base de datos. NO la dejes con el default en un despliegue real: sobreescribila en terraform.tfvars (gitignoreado) o con TF_VAR_db_password"
  type        = string
  sensitive   = true
  default     = "postgrespassword"
}

variable "backend_repo_url" {
  description = "Repositorio Git del backend"
  type        = string
  default     = "https://github.com/aka-leonel/backend-ifts.git"
}

variable "backend_repo_branch" {
  description = "Branch del backend a desplegar"
  type        = string
  default     = "dev"
}

variable "frontend_repo_url" {
  description = "Repositorio Git del frontend"
  type        = string
  default     = "https://github.com/aka-leonel/frontend-miifts.git"
}

variable "frontend_repo_branch" {
  description = "Branch del frontend a desplegar"
  type        = string
  default     = "dev"
}
