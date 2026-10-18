#!/usr/bin/env bash
# Funciones que comparten migrar.sh, respaldo.sh y restaurar.sh. No se corre solo.
# shellcheck disable=SC2034

set -euo pipefail

AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$AQUI"

DC=(docker compose -f "$AQUI/docker-compose.produccion.yml")

falla() { echo "ERROR: $*" >&2; exit 1; }
paso()  { echo; echo "== $*"; }

# Lee UNA variable de un archivo .env sin ejecutarlo (source ejecutaría lo que
# hubiera dentro). Quita comillas envolventes.
leer() {
    local nombre="$1" archivo="$2" valor
    [ -f "$archivo" ] || falla "No existe $archivo."
    valor="$(grep -E "^[[:space:]]*${nombre}=" "$archivo" | tail -n 1 | cut -d= -f2- || true)"
    valor="${valor%$'\r'}"
    valor="${valor#\"}"; valor="${valor%\"}"
    valor="${valor#\'}"; valor="${valor%\'}"
    printf '%s' "$valor"
}

# psql dentro de cada base, por el socket local del contenedor.
psql_fac() { "${DC[@]}" exec -T db-facturacion psql -U facturacion_owner -d facturacion -v ON_ERROR_STOP=1 -q "$@"; }
psql_pla() { "${DC[@]}" exec -T db-plataforma  psql -U postgres          -d plataforma  -v ON_ERROR_STOP=1 -q "$@"; }

# Un texto como literal SQL: comillas simples dobladas.
literal() { local t="$1"; printf "'%s'" "${t//\'/\'\'}"; }

RUTA_PLATAFORMA="$(leer RUTA_PLATAFORMA "$AQUI/.env" 2>/dev/null || true)"
RUTA_PLATAFORMA="${RUTA_PLATAFORMA:-../../../reyban_plataforma}"
MIG_SERVICIO="$AQUI/../migraciones"
MIG_PLATAFORMA="$AQUI/$RUTA_PLATAFORMA/reyban_plataforma_service/migraciones"