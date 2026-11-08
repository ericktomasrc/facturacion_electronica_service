#!/usr/bin/env bash
# =============================================================================
# ROTAR LAS CONTRASEÑAS DE LA BASE — paso 2 de 2, en el SERVIDOR DE APLICACIÓN.
#
#   bash rotar-claves-app.sh
#
# Pide (sin mostrarlas) las cuatro contraseñas que generó rotar-claves-base.sh
# en el servidor de base, las escribe en .env.servicio y en la cadena de
# conexión de .env.plataforma, y vuelve a crear la plataforma, la API y el
# worker para que las lean (restart no relee el .env: hace falta up -d).
# =============================================================================
set -euo pipefail
AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$AQUI"
falla() { echo "ERROR: $*" >&2; exit 1; }

SERVICIO="$AQUI/.env.servicio"
PLATAFORMA="$AQUI/.env.plataforma"
[ -f "$SERVICIO" ]   || falla "No existe $SERVICIO."
[ -f "$PLATAFORMA" ] || falla "No existe $PLATAFORMA."
grep -qE '^PLATAFORMA_CADENA_CONEXION=.*Password=' "$PLATAFORMA" || falla "No encuentro Password= en PLATAFORMA_CADENA_CONEXION de .env.plataforma."

pedir() {
    local etiqueta="$1" valor
    if [ -n "${ROTAR_VALORES:-}" ]; then valor="$(printf '%s\n' "$ROTAR_VALORES" | sed -n "${2}p")"
    else read -r -s -p "  Contraseña de $etiqueta: " valor; echo; fi
    valor="$(printf '%s' "$valor" | tr -d '[:space:]')"
    [[ "$valor" =~ ^[A-Za-z0-9]{32}$ ]] || falla "La de $etiqueta no tiene 32 letras y números. Cópiala otra vez del servidor de base."
    printf '%s' "$valor"
}
P_APP="$(pedir facturacion_app 1)"
P_OPE="$(pedir facturacion_operador 2)"
P_ALTA="$(pedir facturacion_alta 3)"
P_PLA="$(pedir plataforma_app 4)"

poner() {
    local nombre="$1" valor="$2" archivo="$3" tmp
    tmp="$(mktemp "$archivo.XXXXXX")"
    if grep -qE "^[[:space:]]*${nombre}=" "$archivo"; then
        awk -v n="$nombre" -v v="$valor" 'BEGIN{FS=OFS="="} $0 ~ "^[[:space:]]*"n"=" {print n"="v; next} {print}' "$archivo" > "$tmp"
    else
        cat "$archivo" > "$tmp"; printf '%s=%s\n' "$nombre" "$valor" >> "$tmp"
    fi
    chmod --reference="$archivo" "$tmp" 2>/dev/null || chmod 600 "$tmp"
    mv "$tmp" "$archivo"
}
poner FACTURACION_APP_PASSWORD      "$P_APP"  "$SERVICIO"
poner FACTURACION_OPERADOR_PASSWORD "$P_OPE"  "$SERVICIO"
poner FACTURACION_ALTA_PASSWORD     "$P_ALTA" "$SERVICIO"

# En la cadena de conexión: solo el Password=… (lo demás queda igual).
tmp="$(mktemp "$PLATAFORMA.XXXXXX")"
awk -v v="$P_PLA" '/^PLATAFORMA_CADENA_CONEXION=/ { sub(/Password=[^;]*/, "Password=" v) } {print}' "$PLATAFORMA" > "$tmp"
chmod --reference="$PLATAFORMA" "$tmp" 2>/dev/null || chmod 600 "$tmp"
mv "$tmp" "$PLATAFORMA"
echo "  .env.servicio y .env.plataforma actualizados."

if [ "${ROTAR_SIN_DOCKER:-}" != "1" ]; then
    echo; echo "== Volviendo a crear la plataforma, la API y el worker (leen las nuevas)"
    docker compose -f compose.aplicacion.yml --env-file .env.aplicacion up -d --force-recreate plataforma facturacion-api facturacion-worker
    echo; echo "Listo. Revisa en la web que puedes entrar. Si algo falla: docker compose -f compose.aplicacion.yml --env-file .env.aplicacion logs --tail 50 plataforma"
fi