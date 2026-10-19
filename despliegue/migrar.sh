#!/usr/bin/env bash
# =============================================================================
# MIGRAR — aplica las migraciones que falten, en orden, a las dos bases.
#
#   ./migrar.sh                         aplica lo pendiente y comprueba
#   ./migrar.sh --marcar-servicio 033   da por aplicadas las del servicio hasta
#                                       la 033 SIN correrlas (base restaurada
#                                       que ya las tenía)
#
# Se puede correr las veces que haga falta: lo aplicado no se repite.
#
# Lo que hace además, por lo hallado en la revisión (despliegue-pendientes §3.3):
#   - La 002 del servicio se aplica SIN su semilla (la clave de API en claro
#     de desarrollo). Y se comprueba que no quedó ninguna clave.
#   - Las contraseñas de los roles se ponen desde .env.servicio y
#     .env.plataforma, nunca las que traen la 001 de cada lado.
#   - Al final corre verificar.sql de la plataforma como plataforma_app, dentro
#     de una transacción que se deshace: no deja datos de prueba.
#
# Se corre en el SERVIDOR DE BASE (QA, opción B′, GUIA-QA.md), con las bases
# arriba:  docker compose -f compose.base.yml --env-file .env.base up -d
# =============================================================================
# shellcheck source=comun.sh
source "$(dirname "$0")/comun.sh"

MARCAR_HASTA=""
if [ "${1:-}" = "--marcar-servicio" ]; then
    MARCAR_HASTA="${2:?Falta el número: --marcar-servicio 033}"
fi

[ -d "$MIG_SERVICIO" ]   || falla "No encuentro las migraciones del servicio en $MIG_SERVICIO."
[ -d "$MIG_PLATAFORMA" ] || falla "No encuentro las migraciones de la plataforma en $MIG_PLATAFORMA (mira RUTA_PLATAFORMA en .env)."

# 038: las contraseñas de los roles, del .env.base de este servidor (las
# mismas que usan las aplicaciones en el servidor de aplicación).
P_APP="$(leer FACTURACION_APP_PASSWORD .env.base)"
P_OPE="$(leer FACTURACION_OPERADOR_PASSWORD .env.base)"
P_ALTA="$(leer FACTURACION_ALTA_PASSWORD .env.base)"
P_PLA="$(leer PLATAFORMA_APP_PASSWORD .env.base)"

for v in P_APP P_OPE P_ALTA P_PLA; do
    [ -n "${!v}" ] || falla "Falta una contraseña de rol ($v) en .env.base."
    case "${!v}" in *CAMBIAR*) falla "Una contraseña de rol ($v) sigue con el valor de ejemplo.";; esac
done

# ------------------------------------------------------------------ servicio
paso "Servicio de facturación"

psql_fac <<'SQL'
CREATE TABLE IF NOT EXISTS despliegue_migraciones (
    nombre      text        PRIMARY KEY,
    aplicada_en timestamptz NOT NULL DEFAULT now()
);
REVOKE ALL ON despliegue_migraciones FROM PUBLIC;
SQL

aplicadas="$(psql_fac -tA -c "SELECT nombre FROM despliegue_migraciones")"

for f in "$MIG_SERVICIO"/[0-9]*.sql; do
    nombre="$(basename "$f" .sql)"
    if grep -qxF "$nombre" <<<"$aplicadas"; then continue; fi

    if [ -n "$MARCAR_HASTA" ] && (( 10#${nombre%%_*} <= 10#$MARCAR_HASTA )); then
        psql_fac -c "INSERT INTO despliegue_migraciones (nombre) VALUES ($(literal "$nombre")) ON CONFLICT DO NOTHING"
        echo "  marcada   $nombre (no se corrió)"
        continue
    fi

    if [[ "$nombre" == 002_* ]]; then
        # SIN LA SEMILLA: se salta cada INSERT INTO api_keys hasta su punto y coma.
        awk 'BEGIN{s=0} /^[[:space:]]*INSERT[[:space:]]+INTO[[:space:]]+api_keys/{s=1} s==0{print} s==1 && /;[[:space:]]*$/{s=0}' "$f" | psql_fac > /dev/null
        claves="$(psql_fac -tA -c "SELECT count(*) FROM api_keys")"
        [ "$claves" = "0" ] || falla "Después de la 002 hay $claves clave(s) de API: la semilla de desarrollo no debe estar en producción."
    else
        psql_fac < "$f" > /dev/null
    fi

    psql_fac -c "INSERT INTO despliegue_migraciones (nombre) VALUES ($(literal "$nombre"))"
    echo "  aplicada  $nombre"
done

# Las contraseñas de los roles, desde el .env (por la entrada, no en la línea
# de órdenes: no aparecen en la lista de procesos).
psql_fac <<SQL
ALTER ROLE facturacion_app      PASSWORD $(literal "$P_APP");
ALTER ROLE facturacion_operador PASSWORD $(literal "$P_OPE");
ALTER ROLE facturacion_alta     PASSWORD $(literal "$P_ALTA");
SQL
echo "  contraseñas de facturacion_app, facturacion_operador y facturacion_alta puestas"

# ---------------------------------------------------------------- plataforma
paso "Plataforma"

existe="$(psql_pla -tA -c "SELECT to_regclass('migraciones_aplicadas') IS NOT NULL")"
aplicadas=""
[ "$existe" = "t" ] && aplicadas="$(psql_pla -tA -c "SELECT nombre FROM migraciones_aplicadas")"

for f in "$MIG_PLATAFORMA"/[0-9]*.sql; do
    nombre="$(basename "$f" .sql)"
    if grep -qxF "$nombre" <<<"$aplicadas"; then continue; fi
    psql_pla < "$f" > /dev/null
    # Cada migración se anota sola; por si alguna no lo hiciera, no se repite.
    psql_pla -c "INSERT INTO migraciones_aplicadas (nombre) VALUES ($(literal "$nombre")) ON CONFLICT DO NOTHING"
    echo "  aplicada  $nombre"
done

psql_pla <<SQL
ALTER ROLE plataforma_app PASSWORD $(literal "$P_PLA");
SQL
echo "  contraseña de plataforma_app puesta"

paso "Comprobaciones de la plataforma (verificar.sql, como plataforma_app, sin dejar datos)"
salida="$( { echo 'BEGIN;'; cat "$MIG_PLATAFORMA/verificar.sql"; echo; echo 'ROLLBACK;'; } \
          | "${DC[@]}" exec -T db-plataforma psql -U plataforma_app -d plataforma -v ON_ERROR_STOP=1 2>&1 )" \
    || { echo "$salida" | tail -n 5; falla "verificar.sql falló."; }
echo "$salida" | grep -E "NOTICE: +[0-9]+\." | tail -n 1 | sed 's/.*NOTICE: */  última: /'
echo "$salida" | grep -q "TODAS LAS COMPROBACIONES PASARON" || falla "verificar.sql no terminó en TODAS LAS COMPROBACIONES PASARON."
echo "  TODAS LAS COMPROBACIONES PASARON"

echo
echo "Listo. Ahora, en el SERVIDOR DE APLICACIÓN:  docker compose -f compose.aplicacion.yml --env-file .env.aplicacion up -d"