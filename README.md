# Despliegue de miIFTS en AWS Academy (Learner Lab) - Arquitectura con RDS

Guía rápida para desplegar miIFTS (**backend en EC2 + base de datos en Amazon RDS + frontend en S3**) desde AWS CloudShell, y para eliminar todo al terminar.

Región usada: `us-east-1`.

> Si algo falla en cualquier etapa, ejecutá `etapa_4_cleanup.sh` y empezá de nuevo desde la etapa 1.

## Requisitos

- Un laboratorio de AWS Academy Learner Lab iniciado (esperá a que la luz se ponga verde).
- Acceso a CloudShell desde la consola de AWS (con node y npm disponibles, que ya vienen incluidos).
- El rol `LabInstanceProfile`, que el Learner Lab ya provee. Lo necesita la instancia EC2 para recibir comandos por Systems Manager (SSM).

## Pasos

1. Abrí CloudShell desde la consola de AWS.
2. Traé los scripts a CloudShell clonando la rama correspondiente (`db_rds`) de este repositorio, o subiendo los archivos con *Actions → Upload file*:
   ```bash
   git clone -b db_rds https://github.com/aka-leonel/mi_ifts_deployment.git
   cd mi_ifts_deployment
   ```
3. Ejecutá las etapas **en orden y de a una**, esperando que cada una termine antes de lanzar la siguiente (tené en cuenta que la creación de Amazon RDS en la etapa 1 puede tardar varios minutos):
   ```bash
   bash etapa_1_infraestructura_cloud.sh
   bash etapa_2_backend.sh
   bash etapa_3_frontend.sh
   ```
4. Al terminar, la etapa 3 imprime la URL de la PWA. La API queda en `http://<IP-pública>:8000` (la documentación en `/docs`).

> **IMPORTANTE:** para liberar recursos y no consumir tus créditos, ejecutá al finalizar:
> ```bash
> bash etapa_4_cleanup.sh
> ```

## Arquitectura final desplegada

*(Nota: La base de datos PostgreSQL ya no vive dentro de Docker en la EC2, sino de forma desacoplada en un servicio administrado Amazon RDS).*


## Detalle de cada etapa

### etapa_1_infraestructura_cloud.sh
Crea la VPC, dos subredes públicas (en distintas zonas de disponibilidad para cumplir con los requisitos de RDS), el Internet Gateway, la tabla de ruteo, los Security Groups, la instancia EC2 (Ubuntu 22.04, `t3.micro`) y la base de datos **Amazon RDS (PostgreSQL 16)**. Todos los recursos llevan tag `Name` con prefijo `miifts`.

- Configura dos Security Groups separados: uno para la EC2 (puertos **80** y **8000** abiertos al público) y otro exclusivo para RDS (puerto **5432** accesible únicamente desde el Security Group de la EC2).
- Guarda cada ID y el endpoint de la base de datos en `~/miifts-ids.sh` apenas se crean, para que las etapas siguientes los reutilicen.
- Si detecta que ya existe `~/miifts-ids.sh`, **no se ejecuta**: significa que hay un despliegue sin limpiar. Corré primero la etapa 4.

### etapa_2_backend.sh
Espera a que la instancia esté registrada en SSM y le envía, mediante Systems Manager, un script que:

1. Instala Docker y Docker Compose en la EC2.
2. Clona la rama `dev` del backend (`backend-ifts`).
3. Configura el archivo `.env` apuntando la variable `DATABASE_URL` directamente hacia el Endpoint del servicio **Amazon RDS**.
4. Levanta el contenedor de la API mediante Docker Compose (sin contenedor local de base de datos).
5. Espera a que la API responda y ejecuta `seed.py` **una sola vez** para poblar la base de datos remota en RDS.

Al final verifica desde CloudShell que el backend responde en `http://<IP-pública>:8000`. Puede tardar varios minutos. Si el despliegue falla, la etapa termina con error.

### etapa_3_frontend.sh
Clona el frontend (`frontend-miifts`, rama `dev`) en `~/frontend-miifts`, configura `VITE_API_URL` con la IP pública del backend, compila con Node.js (Vite) y publica `dist/` en un bucket de S3 con acceso público de lectura y hosting web estático.

- El nombre del bucket (`miifts-frontend-bucket-<timestamp>`) se guarda en `~/miifts-ids.sh`. Si repetís la etapa, reutiliza ese bucket en vez de crear otro.
- Requiere haber ejecutado antes las etapas 1 y 2.

### etapa_4_cleanup.sh
Elimina todos los recursos de miIFTS **buscándolos por tag/nombre o identificador**, sin depender estrictamente de `~/miifts-ids.sh`. Limpia restos de ejecuciones anteriores que hayan fallado a mitad. Solo toca recursos `miifts-*` y nunca la VPC default. Elimina, en este orden:

1. La instancia de **Amazon RDS** (`miifts-db`).
2. Los buckets de S3 `miifts-frontend-bucket-*` (con todo su contenido).
3. Las instancias EC2 `miifts-backend`.
4. Los DB Subnet Groups de RDS, Security Groups, subredes, tablas de ruteo, Internet Gateway y la VPC.

Al final verifica que no quede nada y borra `~/miifts-ids.sh`. Si quedó algún recurso, termina con error: se puede volver a ejecutar sin problema.

## El archivo `~/miifts-ids.sh`

Las etapas se comunican mediante `~/miifts-ids.sh` (en el home de CloudShell), que guarda variables clave como `VPC_ID`, `INSTANCE_ID`, `PUBLIC_IP`, `DB_HOST` y `BUCKET_NAME`.

**Lo genera la etapa 1 automáticamente y no hay que crearlo ni editarlo a mano.** Crearlo antes de la etapa 1 hace que esta se niegue a ejecutarse.

## Notas

- Es un entorno de aprendizaje: el backend queda expuesto por HTTP en el puerto 8000, con credenciales simplificadas y `CORS_ORIGINS=*`. No lo uses en producción tal cual.
- La base de datos ahora está completamente desacoplada en RDS, por lo que si la instancia EC2 se reinicia o se actualiza, los datos guardados en la base de datos no se pierden.