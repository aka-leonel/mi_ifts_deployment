#!/bin/bash
set -e

# ==========================================
# Etapa 0: Generación de secretos -> ~/miifts-secrets.sh
#
# Este script NO contiene ningún secreto, así que se puede subir a GitHub.
#  - SECRET_KEY, claves VAPID y DB_PASSWORD (RDS): se generan acá, en CloudShell.
#  - Credenciales SMTP (Brevo) y DuckDNS (subdominio + token): se piden por consola.
# El archivo resultante vive en el home de CloudShell (fuera de cualquier repo),
# con permisos 600. La etapa 4 (cleanup) NO lo borra, para conservar los valores
# entre despliegues.
# ==========================================

SECRETS_FILE=~/miifts-secrets.sh
IDS_FILE=~/miifts-ids.sh

# Valores no secretos: se ofrecen como default (Enter para aceptarlos)
DEFAULT_SMTP_HOST="smtp-relay.brevo.com"
DEFAULT_SMTP_PORT="587"
DEFAULT_SMTP_FROM="miiftsinfo@gmail.com"
DEFAULT_VAPID_CLAIMS_SUB="mailto:admin@miifts.com"

for cmd in openssl python3; do
  if ! command -v $cmd > /dev/null 2>&1; then
    echo "❌ Falta '$cmd' en este entorno."
    exit 1
  fi
done

ask_yn() {
  local a
  read -r -p "$1 [s/N]: " a
  case "$a" in s|S|si|Si|SI) return 0 ;; *) return 1 ;; esac
}

# Pide un valor visible. Enter conserva el valor actual (se muestra entre corchetes).
ask_value() {
  local var="$1" label="$2" cur v
  cur="${!var}"
  if [ -n "$cur" ]; then
    read -r -p "$label [$cur]: " v
  else
    read -r -p "$label: " v
  fi
  v=$(echo "$v" | tr -d '[:space:]')
  if [ -n "$v" ]; then printf -v "$var" '%s' "$v"; fi
  return 0
}

# Pide un valor secreto sin mostrarlo. Enter conserva el valor actual.
ask_secret() {
  local var="$1" label="$2" cur v
  cur="${!var}"
  if [ -n "$cur" ]; then
    read -r -s -p "$label (Enter para conservar la actual): " v
  else
    read -r -s -p "$label (no se muestra al escribir): " v
  fi
  echo
  v=$(echo "$v" | tr -d '[:space:]')
  if [ -n "$v" ]; then printf -v "$var" '%s' "$v"; fi
  return 0
}

# Hex -> base64url sin padding (formato de las claves VAPID)
b64url() {
  python3 -c 'import sys,base64; print(base64.urlsafe_b64encode(bytes.fromhex(sys.argv[1])).rstrip(b"=").decode())' "$1"
}

# Genera un par de claves VAPID (curva P-256) en VAPID_PUBLIC_KEY / VAPID_PRIVATE_KEY
gen_vapid() {
  local tmp txt priv_hex pub_hex
  tmp=$(mktemp)
  openssl ecparam -name prime256v1 -genkey -noout -out "$tmp" 2> /dev/null
  txt=$(openssl ec -in "$tmp" -text -noout 2> /dev/null)
  rm -f "$tmp"

  priv_hex=$(echo "$txt" | awk '/^priv:/{f=1;next} /^pub:/{f=0} f' | tr -d ' :\n')
  pub_hex=$(echo "$txt" | awk '/^pub:/{f=1;next} /^ASN1 OID/{f=0} f' | tr -d ' :\n')

  # La clave privada puede traer un byte "00" adelante: nos quedamos con los últimos 32 bytes
  priv_hex=${priv_hex: -64}

  if [ ${#priv_hex} -ne 64 ] || [ ${#pub_hex} -ne 130 ]; then
    echo "❌ No se pudieron generar las claves VAPID."
    exit 1
  fi

  VAPID_PRIVATE_KEY=$(b64url "$priv_hex")
  VAPID_PUBLIC_KEY=$(b64url "$pub_hex")
}

SECRET_KEY=""
VAPID_PUBLIC_KEY=""
VAPID_PRIVATE_KEY=""
VAPID_CLAIMS_SUB=""
DB_PASSWORD=""
SMTP_HOST=""
SMTP_PORT=""
SMTP_USER=""
SMTP_PASSWORD=""
SMTP_FROM=""
DUCKDNS_SUBDOMAIN=""
DUCKDNS_TOKEN=""

EXISTS=0
CHANGED=0
CHANGE_SMTP=0
CHANGE_DUCK=0

if [ -f "$SECRETS_FILE" ]; then
  EXISTS=1
  echo "ℹ️  Ya existe $SECRETS_FILE."
  source "$SECRETS_FILE"

  echo "   Regenerar SECRET_KEY y VAPID cierra las sesiones activas e invalida las"
  echo "   suscripciones push. Además, la clave pública VAPID se compila dentro del"
  echo "   frontend (etapa 3)."
  if ask_yn "¿Regenerar SECRET_KEY y claves VAPID?"; then
    SECRET_KEY=""
    VAPID_PUBLIC_KEY=""
    VAPID_PRIVATE_KEY=""
  fi
  if ask_yn "¿Ingresar de nuevo las credenciales SMTP (Brevo)?"; then CHANGE_SMTP=1; fi
  if ask_yn "¿Cambiar el subdominio o el token de DuckDNS?"; then CHANGE_DUCK=1; fi
fi

# --- Completar lo que falte (también sirve para archivos de versiones anteriores) ---
if [ -z "$SECRET_KEY" ]; then
  SECRET_KEY=$(openssl rand -hex 32)
  CHANGED=1
fi

if [ -z "$VAPID_PUBLIC_KEY" ] || [ -z "$VAPID_PRIVATE_KEY" ]; then
  gen_vapid
  CHANGED=1
fi

# La contraseña de RDS solo se genera si no existe: cambiarla con una base ya creada
# dejaría al backend sin poder conectarse.
if [ -z "$DB_PASSWORD" ]; then
  DB_PASSWORD=$(openssl rand -hex 16)
  CHANGED=1
  if [ -f "$IDS_FILE" ]; then
    echo "⚠️  Hay un despliegue activo ($IDS_FILE) creado con otra contraseña de RDS."
    echo "   La nueva DB_PASSWORD solo sirve para despliegues nuevos: ejecutá etapa_4_cleanup.sh antes de la etapa 1."
  fi
fi

if [ -z "$VAPID_CLAIMS_SUB" ]; then VAPID_CLAIMS_SUB="$DEFAULT_VAPID_CLAIMS_SUB"; CHANGED=1; fi
if [ -z "$SMTP_HOST" ]; then SMTP_HOST="$DEFAULT_SMTP_HOST"; CHANGED=1; fi
if [ -z "$SMTP_PORT" ]; then SMTP_PORT="$DEFAULT_SMTP_PORT"; CHANGED=1; fi
if [ -z "$SMTP_FROM" ]; then SMTP_FROM="$DEFAULT_SMTP_FROM"; CHANGED=1; fi

if [ -z "$SMTP_USER" ] || [ -z "$SMTP_PASSWORD" ]; then CHANGE_SMTP=1; fi
if [ -z "$DUCKDNS_SUBDOMAIN" ] || [ -z "$DUCKDNS_TOKEN" ]; then CHANGE_DUCK=1; fi

if [ "$CHANGED" = "0" ] && [ "$CHANGE_SMTP" = "0" ] && [ "$CHANGE_DUCK" = "0" ]; then
  echo "Sin cambios: se conserva el archivo actual."
  exit 0
fi

# --- Datos que se piden por consola ---
if [ "$CHANGE_SMTP" = "1" ]; then
  echo "=== CREDENCIALES SMTP (Brevo > SMTP y API > SMTP) ==="
  ask_value SMTP_HOST "SMTP_HOST"
  ask_value SMTP_PORT "SMTP_PORT"
  ask_value SMTP_FROM "SMTP_FROM (remitente)"
  ask_value SMTP_USER "SMTP_USER (login SMTP, ej: xxxxx@smtp-brevo.com)"
  ask_secret SMTP_PASSWORD "SMTP_PASSWORD (clave SMTP)"
fi

if [ "$CHANGE_DUCK" = "1" ]; then
  echo "=== DUCKDNS (https://www.duckdns.org) ==="
  ask_value DUCKDNS_SUBDOMAIN "Subdominio (solo el nombre, sin .duckdns.org)"
  DUCKDNS_SUBDOMAIN=$(echo "$DUCKDNS_SUBDOMAIN" | tr 'A-Z' 'a-z' | sed 's/\.duckdns\.org$//')
  ask_secret DUCKDNS_TOKEN "Token de DuckDNS"
fi

# --- Validaciones ---
for v in SECRET_KEY VAPID_PUBLIC_KEY VAPID_PRIVATE_KEY VAPID_CLAIMS_SUB DB_PASSWORD \
         SMTP_HOST SMTP_PORT SMTP_USER SMTP_PASSWORD SMTP_FROM DUCKDNS_SUBDOMAIN DUCKDNS_TOKEN; do
  if [ -z "${!v}" ]; then
    echo "❌ Falta $v. No se escribió el archivo."
    exit 1
  fi
done

if ! [[ "$DUCKDNS_SUBDOMAIN" =~ ^[a-z0-9-]+$ ]]; then
  echo "❌ El subdominio de DuckDNS solo puede tener letras, números y guiones. No se escribió el archivo."
  exit 1
fi

# --- Escritura con permisos restrictivos (%q deja los valores listos para 'source') ---
umask 077
{
  echo "# Generado por etapa_0_secrets.sh - NO subir a GitHub"
  for v in SECRET_KEY VAPID_PUBLIC_KEY VAPID_PRIVATE_KEY VAPID_CLAIMS_SUB DB_PASSWORD \
           SMTP_HOST SMTP_PORT SMTP_USER SMTP_PASSWORD SMTP_FROM DUCKDNS_SUBDOMAIN DUCKDNS_TOKEN; do
    printf 'export %s=%q\n' "$v" "${!v}"
  done
} > "$SECRETS_FILE"
chmod 600 "$SECRETS_FILE"

# Verificación: el archivo se puede cargar y trae todos los valores
(
  source "$SECRETS_FILE"
  for v in SECRET_KEY VAPID_PUBLIC_KEY VAPID_PRIVATE_KEY VAPID_CLAIMS_SUB DB_PASSWORD \
           SMTP_HOST SMTP_PORT SMTP_USER SMTP_PASSWORD SMTP_FROM DUCKDNS_SUBDOMAIN DUCKDNS_TOKEN; do
    if [ -z "${!v}" ]; then
      echo "❌ $v quedó vacío en $SECRETS_FILE"
      exit 1
    fi
  done
)

echo "=========================================="
echo "✅ SECRETOS LISTOS en $SECRETS_FILE (permisos 600)"
echo "Dominio configurado: https://${DUCKDNS_SUBDOMAIN}.duckdns.org"
if [ "$EXISTS" = "1" ] && [ -f "$IDS_FILE" ]; then
  echo "Hay un despliegue activo: para aplicar cambios de SECRET_KEY, VAPID, SMTP o DuckDNS"
  echo "volvé a ejecutar ./etapa_2_backend.sh y, si cambiaron VAPID o el dominio, ./etapa_3_frontend.sh"
else
  echo "Siguiente paso: ./etapa_1_infraestructura_cloud.sh"
fi
echo "=========================================="
