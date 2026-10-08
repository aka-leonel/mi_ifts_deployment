#!/bin/bash
set -e

# ==========================================
# Etapa 0: Generación de secretos -> ~/miifts-secrets.sh
#
# Este script NO contiene ningún secreto, así que se puede subir a GitHub.
#  - SECRET_KEY y claves VAPID: se generan acá, en CloudShell.
#  - SMTP_USER y SMTP_PASSWORD (Brevo): se piden por consola.
# El archivo resultante vive en el home de CloudShell (fuera de cualquier repo),
# con permisos 600. La etapa 4 (cleanup) NO lo borra, para conservar las claves
# entre despliegues.
# ==========================================

SECRETS_FILE=~/miifts-secrets.sh

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
SMTP_USER=""
SMTP_PASSWORD=""
REGEN_KEYS=1
CHANGE_SMTP=1

if [ -f "$SECRETS_FILE" ]; then
  echo "ℹ️  Ya existe $SECRETS_FILE."
  source "$SECRETS_FILE"
  REGEN_KEYS=0
  CHANGE_SMTP=0
  echo "   Regenerar SECRET_KEY y VAPID cierra las sesiones activas e invalida las"
  echo "   suscripciones de notificaciones push existentes."
  if ask_yn "¿Regenerar SECRET_KEY y claves VAPID?"; then REGEN_KEYS=1; fi
  if ask_yn "¿Ingresar de nuevo las credenciales SMTP?"; then CHANGE_SMTP=1; fi
  if [ "$REGEN_KEYS" = "0" ] && [ "$CHANGE_SMTP" = "0" ]; then
    echo "Sin cambios: se conserva el archivo actual."
    exit 0
  fi
fi

if [ "$REGEN_KEYS" = "1" ]; then
  echo "=== GENERANDO SECRET_KEY Y CLAVES VAPID ==="
  SECRET_KEY=$(openssl rand -hex 32)
  gen_vapid
fi

if [ "$CHANGE_SMTP" = "1" ]; then
  echo "=== CREDENCIALES SMTP (Brevo > SMTP y API > SMTP) ==="
  read -r -p "SMTP_USER (login SMTP, ej: xxxxx@smtp-brevo.com): " SMTP_USER
  read -r -s -p "SMTP_PASSWORD (clave SMTP, no se muestra al escribir): " SMTP_PASSWORD
  echo
  SMTP_USER=$(echo "$SMTP_USER" | tr -d '[:space:]')
  SMTP_PASSWORD=$(echo "$SMTP_PASSWORD" | tr -d '[:space:]')
fi

if [ -z "$SECRET_KEY" ] || [ -z "$VAPID_PUBLIC_KEY" ] || [ -z "$VAPID_PRIVATE_KEY" ] || [ -z "$SMTP_USER" ] || [ -z "$SMTP_PASSWORD" ]; then
  echo "❌ Falta algún valor. No se escribió el archivo."
  exit 1
fi

# Escritura con permisos restrictivos (%q deja los valores listos para 'source')
umask 077
{
  echo "# Generado por etapa_0_secrets.sh - NO subir a GitHub"
  printf 'export SECRET_KEY=%q\n' "$SECRET_KEY"
  printf 'export VAPID_PUBLIC_KEY=%q\n' "$VAPID_PUBLIC_KEY"
  printf 'export VAPID_PRIVATE_KEY=%q\n' "$VAPID_PRIVATE_KEY"
  printf 'export SMTP_PASSWORD=%q\n' "$SMTP_PASSWORD"
  printf 'export SMTP_USER=%q\n' "$SMTP_USER"
} > "$SECRETS_FILE"
chmod 600 "$SECRETS_FILE"

# Verificación: el archivo se puede cargar y trae los 5 valores
(
  source "$SECRETS_FILE"
  for v in SECRET_KEY VAPID_PUBLIC_KEY VAPID_PRIVATE_KEY SMTP_USER SMTP_PASSWORD; do
    if [ -z "${!v}" ]; then
      echo "❌ $v quedó vacío en $SECRETS_FILE"
      exit 1
    fi
  done
)

echo "=========================================="
echo "✅ SECRETOS LISTOS en $SECRETS_FILE (permisos 600)"
echo "Siguiente paso: bash etapa_1_infraestructura_cloud.sh"
echo "=========================================="