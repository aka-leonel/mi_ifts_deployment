# Despliegue de miIFTS en AWS Academy (Learner Lab) - RDS + dominio DuckDNS con HTTPS

Guía rápida para desplegar miIFTS desde AWS CloudShell y para eliminar todo al terminar. La aplicación queda disponible en un dominio `https://<subdominio>.duckdns.org` con certificado HTTPS automático:

- **Backend** (API) en un contenedor Docker dentro de una EC2.
- **Caddy** (también en la EC2): emite y renueva el certificado HTTPS, sirve la PWA y reenvía `/api/*` a la API.
- **Base de datos** en Amazon RDS (PostgreSQL), desacoplada de la EC2.
- **Elastic IP** fija para la EC2, a la que apunta el subdominio de DuckDNS.

Región usada: `us-east-1`.

> Si algo falla en cualquier etapa de la 1 a la 3, ejecutá `./etapa_4_cleanup.sh` 2 (dos) veces y empezá de nuevo desde la etapa 1. La etapa 0 no hace falta repetirla: tus secretos se conservan en `~/miifts-secrets.sh`.

## Requisitos

- Un laboratorio de AWS Academy Learner Lab iniciado (esperá a que la luz se ponga verde).
- Acceso a CloudShell desde la consola de AWS (con `node`, `npm`, `git`, `openssl`, `python3` y `curl` disponibles, que ya vienen incluidos).
- El rol `LabInstanceProfile`, que el Learner Lab ya provee. Lo necesita la instancia EC2 para recibir comandos por Systems Manager (SSM).
- Una cuenta de **DuckDNS** (https://www.duckdns.org) con un subdominio creado y su **token**.
- Una cuenta de **Brevo** con credenciales SMTP (usuario y clave SMTP, en *SMTP y API → SMTP*), usadas para enviar el mail de recuperación de contraseña.

## Pasos

1. Abrí CloudShell desde la consola de AWS.

2. Traé los scripts a CloudShell clonando la rama `dominio-duck-dns` de este repositorio, o subiendo los archivos con *Actions → Upload file*:
   ```bash
   git clone -b dominio-duck-dns https://github.com/aka-leonel/mi_ifts_deployment.git
   cd mi_ifts_deployment
   ```

3. Dale permiso de ejecución (`chmod +x`) a cada script:
   ```bash
   chmod +x etapa_0_secrets.sh
   chmod +x etapa_1_infraestructura_cloud.sh
   chmod +x etapa_2_backend.sh
   chmod +x etapa_3_frontend.sh
   chmod +x etapa_4_cleanup.sh
   ```

4. Ejecutá las etapas **en orden y de a una**, esperando que cada una termine antes de lanzar la siguiente (tené en cuenta que la creación de Amazon RDS en la etapa 1 puede tardar varios minutos):
   ```bash
   ./etapa_0_secrets.sh      # solo la primera vez: pide por consola SMTP (Brevo) y DuckDNS
   ./etapa_1_infraestructura_cloud.sh
   ./etapa_2_backend.sh
   ./etapa_3_frontend.sh
   ```

5. Al terminar, la etapa 3 imprime las direcciones: la PWA en `https://<subdominio>.duckdns.org` y la API en `https://<subdominio>.duckdns.org/api/`. La primera vez puede tardar un par de minutos hasta que Caddy emite el certificado.

6. Liberar recursos

> **IMPORTANTE:** para liberar recursos y no consumir tus créditos, ejecutá al finalizar:
> ```bash
> ./etapa_4_cleanup.sh
> ```

## Arquitectura final desplegada

*(Nota: La base de datos PostgreSQL no vive dentro de Docker en la EC2, sino de forma desacoplada en un servicio administrado Amazon RDS).*

![Arquitectura de miIFTS](./img/arquitectura-miifts.png)

Flujo de una petición: el navegador entra a `https://<subdominio>.duckdns.org` → DuckDNS resuelve a la Elastic IP → Caddy (puertos 80/443 de la EC2) responde con la PWA o, si la ruta empieza con `/api/`, reenvía a la API (puerto 8000, solo accesible desde la propia EC2) → la API consulta RDS (puerto 5432, solo accesible desde el Security Group de la EC2).

## Detalle de cada etapa

### etapa_0_secrets.sh
Genera el archivo `~/miifts-secrets.sh` (en el home de CloudShell, con permisos `600`) que usan las etapas 1, 2 y 3. **El script no contiene ningún secreto**, por eso se puede versionar en GitHub: los valores se generan o se piden en el momento.

- `SECRET_KEY`, las claves VAPID (`VAPID_PUBLIC_KEY`, `VAPID_PRIVATE_KEY`, para notificaciones push) y `DB_PASSWORD` (contraseña de RDS) **se generan automáticamente** con `openssl`.
- Por consola se piden: servidor y credenciales SMTP de Brevo (`SMTP_HOST`, `SMTP_PORT`, `SMTP_FROM`, `SMTP_USER`, `SMTP_PASSWORD`; los tres primeros traen un valor por defecto que aceptás con Enter) y el **subdominio y token de DuckDNS**. Las claves se escriben sin mostrarse en pantalla.
- Si `~/miifts-secrets.sh` ya existe, pregunta qué querés cambiar (regenerar `SECRET_KEY` y VAPID, volver a ingresar el SMTP, cambiar DuckDNS). También completa lo que falte si el archivo viene de una versión anterior. Si respondés que no a todo y no falta nada, no modifica nada, así que se puede volver a ejecutar sin riesgo.
- `DB_PASSWORD` solo se genera la primera vez: cambiarla con una base ya creada dejaría al backend sin conexión.
- Regenerar `SECRET_KEY` cierra las sesiones activas, y regenerar las claves VAPID invalida las suscripciones push existentes. **La clave pública VAPID se compila dentro del frontend**, por lo que si cambia hay que volver a ejecutar las etapas 2 y 3.
- La etapa 4 **no** borra este archivo, para que los valores se conserven entre despliegues.

### etapa_1_infraestructura_cloud.sh
Crea la VPC, dos subredes públicas (en distintas zonas de disponibilidad para cumplir con los requisitos de RDS), el Internet Gateway, la tabla de ruteo, los Security Groups, la instancia EC2 (Ubuntu 22.04, `t3.micro`) con una **Elastic IP**, y la base de datos **Amazon RDS (PostgreSQL 16)**. Todos los recursos llevan tag `Name` con prefijo `miifts`.

- Configura dos Security Groups separados: uno para la EC2 (puertos **80** y **443** abiertos al público; el 80 es necesario para el desafío de Let's Encrypt) y otro exclusivo para RDS (puerto **5432** accesible únicamente desde el Security Group de la EC2). El puerto 8000 de la API ya no se expone.
- Crea RDS con la contraseña `DB_PASSWORD` de `~/miifts-secrets.sh` y con la base `miifts` ya creada.
- Guarda cada ID y el endpoint de la base de datos en `~/miifts-ids.sh` apenas se crean, para que las etapas siguientes los reutilicen.
- Si detecta que ya existe `~/miifts-ids.sh`, **no se ejecuta**: significa que hay un despliegue sin limpiar. Corré primero la etapa 4. Si falta `~/miifts-secrets.sh`, te indica que corras la etapa 0.

### etapa_2_backend.sh
Carga `~/miifts-secrets.sh` (si falta o está incompleto, se detiene y te avisa que corras la etapa 0), **actualiza el registro de DuckDNS** para que el subdominio apunte a la Elastic IP, espera a que la instancia esté registrada en SSM y le envía, mediante Systems Manager, un script que:

1. Instala Docker en la EC2.
2. Clona (o actualiza) la rama `dev` del backend (`backend-ifts`).
3. Genera el archivo `.env` con: `DATABASE_URL` apuntando al Endpoint de **Amazon RDS**, `SECRET_KEY`, las claves VAPID, la configuración SMTP de Brevo, `CORS_ORIGINS` (solo el dominio) y `FRONTEND_RESET_PASSWORD_URL` (ver más abajo).
4. Construye la imagen y levanta el contenedor `miifts-api` (sin contenedor local de base de datos).
5. Espera a que la API responda (las migraciones se aplican al iniciar) y ejecuta `seed.py` para poblar la base de datos remota en RDS.
6. Levanta **Caddy** (contenedor `caddy`) con un `Caddyfile` para el dominio: HTTPS automático, `/api/*` hacia la API y el resto desde `/home/ubuntu/frontend-dist`.

Guarda el dominio (`DOMAIN`) en `~/miifts-ids.sh` para la etapa 3. Puede tardar varios minutos. Si el despliegue falla, la etapa termina con error y muestra los últimos logs. Se puede volver a ejecutar para aplicar cambios de configuración (recrea los contenedores).

### etapa_3_frontend.sh
Clona el frontend (`frontend-miifts`, rama `dev`) en `~/frontend-miifts`, escribe su `.env` con `VITE_API_URL=https://<dominio>/api` y la clave pública VAPID, y compila con Node.js (Vite).

- Instala `git-lfs` si hace falta y descarga las imágenes del frontend (están en Git LFS). Si quedan punteros LFS sin resolver, **no publica**, para evitar una app sin logo ni íconos.
- Para llevar el build a la EC2 lo comprime, lo sube a un **bucket S3 privado temporal** (`miifts-frontend-bucket-<timestamp>`, guardado en `~/miifts-ids.sh`) y le pasa a la EC2, por SSM, una URL prefirmada de 15 minutos. La EC2 lo descarga y lo descomprime en `/home/ubuntu/frontend-dist`, que es lo que sirve Caddy. Luego borra el archivo del bucket.
- Al final verifica que `https://<dominio>/` responda. Si el certificado todavía no está listo, avisa y se puede reintentar en unos minutos.
- Requiere haber ejecutado antes las etapas 1 y 2. Se puede repetir sola para publicar una nueva versión del frontend.

### etapa_4_cleanup.sh
Elimina los recursos de miIFTS **buscándolos por tag/nombre o identificador**, sin depender estrictamente de `~/miifts-ids.sh`. Limpia restos de ejecuciones anteriores que hayan fallado a mitad. Solo toca recursos `miifts-*` y nunca la VPC default. Elimina, en este orden:

1. La instancia de **Amazon RDS** (`miifts-db`).
2. El DB Subnet Group de RDS (reintenta hasta que AWS lo libera).
3. Los buckets de S3 `miifts-frontend-bucket-*` (con todo su contenido).
4. Las instancias EC2 `miifts-backend`.
5. Vacía el registro de DuckDNS (mejor esfuerzo) y libera las **Elastic IP** `miifts-eip`, que cobran si quedan sin asociar.
6. De la VPC `miifts-vpc`: Security Groups, subredes, tablas de ruteo, Internet Gateway y la propia VPC.

Al final borra `~/miifts-ids.sh`. El script **no verifica ni devuelve error** si algún recurso no se pudo eliminar: por eso se recomienda ejecutarlo dos veces y, si quedan dudas, usar `check_orphans.sh`. No borra `~/miifts-secrets.sh`.

### El archivo check_orphans.sh
Este archivo es un auxiliar que sirve para listar todos los servicios que están levantados específicamente en la región us-east-1. En caso de que cleanup falle en limpiar todos los recursos (sobre todo VPCs e IGWs) este script puede dar una pista.

## Recuperación de contraseña por email

El backend envía el mail de "Olvidé mi contraseña" por SMTP (Brevo). El link del mail se arma con la variable `FRONTEND_RESET_PASSWORD_URL`, que la etapa 2 define como:

```
https://<subdominio>.duckdns.org/reset-password
```

Sin esa variable, el backend usa `http://localhost:5173/reset-password` por defecto y el link del mail no funcionaría fuera de un entorno local. Si cambia el dominio (por ejemplo, otro subdominio de DuckDNS), corré `./etapa_0_secrets.sh` para actualizarlo y volvé a ejecutar las etapas 2 y 3.

## Archivos auxiliares en el home de CloudShell

Las etapas se comunican mediante dos archivos que viven en `~` (fuera del repositorio, por eso nunca se suben a GitHub):

**`~/miifts-ids.sh`** guarda variables clave como `VPC_ID`, `INSTANCE_ID`, `ALLOC_ID` (Elastic IP), `PUBLIC_IP`, `DB_HOST`, `DOMAIN` y `BUCKET_NAME`. **Lo genera la etapa 1 automáticamente (la etapa 2 le agrega `DOMAIN` y la etapa 3 `BUCKET_NAME`); no hay que crearlo ni editarlo a mano.** Crearlo antes de la etapa 1 hace que esta se niegue a ejecutarse. La etapa 4 lo borra.

**`~/miifts-secrets.sh`** guarda `SECRET_KEY`, las claves VAPID, `DB_PASSWORD`, las credenciales SMTP y los datos de DuckDNS. Lo genera la etapa 0. La etapa 4 no lo borra. **Nunca lo subas a un repositorio.**

## Notas

- Es un entorno de aprendizaje. La API ya no queda expuesta en el puerto 8000 y `CORS_ORIGINS` se limita al dominio, pero los secretos viajan a la EC2 dentro del comando de SSM (queda en el historial de Systems Manager de la cuenta). No lo uses en producción tal cual.
- La base de datos está completamente desacoplada en RDS, por lo que si la instancia EC2 se reinicia o se actualiza, los datos guardados en la base de datos no se pierden.
- Cada despliegue desde cero pide un certificado nuevo a Let's Encrypt para el mismo dominio, y Let's Encrypt limita la cantidad de certificados idénticos por semana (alrededor de 5). Si repetís muchos despliegues seguidos, el certificado puede demorar o fallar hasta que se libere el límite.
