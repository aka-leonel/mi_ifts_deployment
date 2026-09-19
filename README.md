## Esto es una guía rápida.
Para una guía paso a paso -o si tenés errores- leer: deployment-guide.md

## Pasos

1. Iniciar el laboratiorio de AWS, esperar que la luz se ponga verde e ir a la consola de CloudShell.

Copiar y pegar en la consola secuencialmente el contenido de 
etapa_1_infraestructura_cloud.sh
etapa_2_backend.sh  
etapa_3._frontendsh

Si hay errores, seguir el paso a paso de deployment-guide.md

### Un poco de detalle.
etapa_1_infraestructura_cloud.sh (creación de red, VPC, subred, internet gateway, tabla de ruteo, security groups y la instancia EC2):			 deja guardadas las variables necesarias para que luego puedas continuar con el despliegue del backend y frontend.

etapa_2_backend.sh
Copia el contenido en tu CloudShell. Lo que hace es conectarse automáticamente a la instancia EC2 mediante Systems Manager (ssm), clonar la rama dev del backend, configurar el archivo .env, levantar los contenedores con Docker Compose y ejecutar el script seed.py para poblar la base de datos.

etapa_3_frontend.sh
Crea este archivo en CloudShell. Se encarga de clonar el repositorio del frontend, configurar la variable de entorno apuntando a la IP pública de tu backend, compilar con Node.js y publicar todo en un bucket de Amazon S3 con acceso público web.