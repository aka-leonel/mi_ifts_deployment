## Esto es una guía rápida.
Para una guía paso a paso -o si tenés errores- leer: deployment-guide.md



## Pasos

1. Iniciar el laboratiorio de AWS, esperar que la luz se ponga verde e ir a la consola de CloudShell.

Copiar y pegar en la consola secuencialmente el contenido de 
etapa_1_infraestructura_cloud.sh
etapa_2_backend.sh  
etapa_3._frontendsh

-- IMPORTANTE: para liberar recursos y no consumir tus créditos ejecutar al finalizar:
etapa_4_cleanup.sh

Si hay errores, seguir el paso a paso de deployment-guide.md

### Un poco de detalle.
etapa_1_infraestructura_cloud.sh (creación de red, VPC, subred, internet gateway, tabla de ruteo, security groups y la instancia EC2):			 deja guardadas las variables necesarias para que luego puedas continuar con el despliegue del backend y frontend.

etapa_2_backend.sh
Copia el contenido en tu CloudShell. Lo que hace es conectarse automáticamente a la instancia EC2 mediante Systems Manager (ssm), clonar la rama dev del backend, configurar el archivo .env, levantar los contenedores con Docker Compose y ejecutar el script seed.py para poblar la base de datos.

etapa_3_frontend.sh
Crea este archivo en CloudShell. Se encarga de clonar el repositorio del frontend, configurar la variable de entorno apuntando a la IP pública de tu backend, compilar con Node.js y publicar todo en un bucket de Amazon S3 con acceso público web.

etapa_4_cleanup.sh
Como creamos recursos en orden inverso (primero los que dependen de otros), el script se encargará de eliminar:
a. El bucket de S3 del frontend.
b. La instancia EC2.
c. El Security Group.
d. La tabla de ruteo, subred, Internet Gateway y la VPC.


### Configuración previa (Variables de Entorno)
Para que los scripts de las distintas etapas se comuniquen entre sí (especialmente la EC2 y la IP pública), el sistema utiliza un archivo de configuración llamado `miifts-ids.sh`.
NOTA: Si ejecutas la Etapa 1 (etapa_1_infraestructura_cloud.sh), este archivo se generará y completará automáticamente de forma dinámica en tu CloudShell.

1. Copia la plantilla provista en el repositorio:
   ```bash
   cp miifts-ids.template.sh miifts-ids.sh

   

Si prefieres desplegar manualmente o recuperar una sesión previa, abre el archivo miifts-ids.sh y completa los datos de tu infraestructura de AWS (VPC_ID, INSTANCE_ID, PUBLIC_IP, etc.).