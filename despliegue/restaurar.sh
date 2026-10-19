#!/usr/bin/env bash
# =============================================================================
# RESTAURAR — «una copia que nunca se restauró no es una copia».
#
#   ./restaurar.sh --probar respaldos/respaldo-2026-10-16_0300.tar.gz
#       Lo restaura en un PostgreSQL APARTE y temporal, y compara los conteos
#       con los que anotó el respaldo. No toca nada de producción. Hazlo el
#       mismo día del despliegue y después una vez al mes.
#
#   ./restaurar.sh --de-verdad respaldos/respaldo-...tar.gz --borra-lo-actual
#       Para el desastre: detiene las API y el Worker, REEMPLAZA las dos bases
#       y el almacén por lo del respaldo, y los vuelve a arrancar. Sin
#       --borra-lo-actual no hace nada.
# =============================================================================
# shellcheck source=comun.sh
source "$(dirname "$0")/comun.sh"

MODO="${1:-}"; ARCHIVO="${2:-}"
{ [ -n "$MODO" ] && [ -f "$ARCHIVO" ]; } || falla "Uso: ./restaurar.sh --probar <respaldo.tar.gz>  |  --de-verdad <respaldo.tar.gz> --borra-lo-actual"

TMP="$(mktemp -d)"
PRUEBA="reyban-prueba-restaurar"
trap 'rm -rf "$TMP"; docker rm -f "$PRUEBA" >/dev/null 2>&1 || true' EXIT
tar -xzf "$ARCHIVO" -C "$TMP"
{ [ -f "$TMP/facturacion.dump" ] && [ -f "$TMP/plataforma.dump" ]; } || falla "El archivo no trae las dos bases."

esperado() { grep -E "^$1=" "$TMP/conteos.txt" | cut -d= -f2; }

# Los roles no van en un pg_dump (son del servidor, no de la base): se crean
# vacíos para que los permisos y las políticas se restauren tal cual.
ROLES="facturacion_owner facturacion_app facturacion_operador facturacion_alta plataforma_app plataforma_puertas"

case "$MODO" in
--probar)
    paso "PostgreSQL temporal ($PRUEBA)"
    docker rm -f "$PRUEBA" >/dev/null 2>&1 || true
    docker run -d --name "$PRUEBA" -e POSTGRES_PASSWORD=solo-para-probar postgres:16-alpine >/dev/null
    for _ in $(seq 1 30); do docker exec "$PRUEBA" pg_isready -U postgres >/dev/null 2>&1 && break; sleep 1; done
    sleep 2
    for r in $ROLES; do docker exec "$PRUEBA" psql -U postgres -qc "CREATE ROLE $r" >/dev/null; done
    docker exec "$PRUEBA" psql -U postgres -qc "ALTER ROLE plataforma_puertas BYPASSRLS" -c "ALTER ROLE facturacion_operador BYPASSRLS" -c "ALTER ROLE facturacion_alta BYPASSRLS" >/dev/null
    docker exec "$PRUEBA" psql -U postgres -qc "CREATE DATABASE facturacion OWNER facturacion_owner" -c "CREATE DATABASE plataforma" >/dev/null

    paso "Restaurando"
    docker exec -i "$PRUEBA" pg_restore -U postgres -d facturacion --exit-on-error < "$TMP/facturacion.dump"
    docker exec -i "$PRUEBA" pg_restore -U postgres -d plataforma  --exit-on-error < "$TMP/plataforma.dump"

    paso "Comparando conteos"
    mal=0
    comparar() {
        local nombre="$1" base="$2" tabla="$3" real esp
        real="$(docker exec "$PRUEBA" psql -U postgres -d "$base" -tAc "SELECT count(*) FROM $tabla")"
        esp="$(esperado "$nombre")"
        if [ "$real" -ge "$esp" ]; then echo "  $nombre: $real (al empezar el respaldo: $esp)  ✓"; else echo "  $nombre: $real (el respaldo dice $esp)  ✗"; mal=1; fi
    }
    comparar comprobantes facturacion comprobantes
    comparar tenants      facturacion tenants
    comparar empresas     plataforma  empresas
    comparar documentos   plataforma  documentos
    if [ -f "$TMP/almacen.tar" ]; then
        echo "  almacén: $(tar -tf "$TMP/almacen.tar" | grep -vc '/$') archivo(s) en el respaldo"
    fi
    [ "$mal" = 0 ] || falla "Los conteos no coinciden."
    echo
    echo "RESTAURACIÓN PROBADA: el respaldo $(basename "$ARCHIVO") se puede restaurar."
    ;;

--de-verdad)
    [ "${3:-}" = "--borra-lo-actual" ] || falla "Esto reemplaza las bases de producción. Si es lo que quieres, añade --borra-lo-actual."
    # 038 (QA, opción B′): la aplicación vive en el OTRO servidor.
    paso "La aplicación tiene que estar detenida"
    echo "  En el SERVIDOR DE APLICACIÓN:  docker compose -f compose.aplicacion.yml --env-file .env.aplicacion stop"
    read -r -p "  ¿Ya está detenida? Escribe SI para seguir: " detenida
    [ "$detenida" = "SI" ] || falla "Cancelado. No se tocó nada."
    paso "Roles (un pg_dump no los lleva; en un servidor nuevo no existen)"
    "${DC[@]}" up -d db-facturacion db-plataforma
    sleep 5
    for r in facturacion_app facturacion_operador facturacion_alta; do
        psql_fac -c "DO \$\$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '$r') THEN CREATE ROLE $r LOGIN; END IF; END \$\$"
    done
    psql_fac -c "ALTER ROLE facturacion_operador BYPASSRLS" -c "ALTER ROLE facturacion_alta BYPASSRLS"
    psql_pla -c "DO \$\$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'plataforma_app') THEN CREATE ROLE plataforma_app LOGIN; END IF; IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'plataforma_puertas') THEN CREATE ROLE plataforma_puertas NOLOGIN BYPASSRLS; END IF; END \$\$"
    paso "Bases"
    "${DC[@]}" exec -T db-facturacion pg_restore -U facturacion_owner -d facturacion --clean --if-exists --exit-on-error < "$TMP/facturacion.dump"
    "${DC[@]}" exec -T db-plataforma  pg_restore -U postgres          -d plataforma  --clean --if-exists --exit-on-error < "$TMP/plataforma.dump"
    if [ -f "$TMP/almacen.tar" ]; then
        paso "Almacén"
        almacen="$("${DC[@]}" ps -aq almacen)"
        [ -n "$almacen" ] || falla "No existe el contenedor «almacen» (créalo con: docker compose ... up -d almacen)."
        docker run --rm -i --volumes-from "$almacen" alpine:3.20 sh -c 'find /data -mindepth 1 -delete && tar -C /data -xf -' < "$TMP/almacen.tar"
    fi
    paso "Arrancando"
    "${DC[@]}" up -d
    echo "Las contraseñas de los roles: corre ./migrar.sh ahora (las pone desde los .env; no repite migraciones)."
    echo
    echo "Restaurado. En el SERVIDOR DE APLICACIÓN: docker compose -f compose.aplicacion.yml --env-file .env.aplicacion up -d"
    ;;
*)
    falla "Modo desconocido: $MODO"
    ;;
esac