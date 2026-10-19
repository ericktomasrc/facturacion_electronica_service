#!/usr/bin/env bash
# =============================================================================
# RESPALDO — las dos bases y el almacén (XML, CDR, PDF, certificados cifrados,
# logos) en un solo archivo con fecha:  respaldos/respaldo-2026-10-16_0300.tar.gz
#
#   ./respaldo.sh
#
# En cron, a las 04:30 de Lima (después de la prueba de madrugada; el servidor está en UTC):
#   30 9 * * *  /opt/reyban/facturacion\ electronica/facturacion_electronica_service/despliegue/respaldo.sh >> /var/log/reyban-respaldo.log 2>&1
#
# Guarda 7 diarios y 4 semanales (los del domingo); lo más viejo se borra.
#
# LO QUE NO LLEVA, A PROPÓSITO: los .env (la llave maestra y las contraseñas).
# Un respaldo con los datos Y la llave que los descifra es un regalo para quien
# lo encuentre. Las llaves viven en el gestor de contraseñas (GUIA §8). SIN LA
# LLAVE MAESTRA, LOS CERTIFICADOS DEL RESPALDO NO SIRVEN: guárdala allí hoy.
#
# Copia fuera del servidor: si en .env está RESPALDO_RCLONE_DESTINO (por
# ejemplo r2:reyban-respaldos) y rclone está instalado, se sube allí. Un
# respaldo que vive en el mismo disco que la base no es un respaldo.
# =============================================================================
# shellcheck source=comun.sh
source "$(dirname "$0")/comun.sh"

FECHA="$(TZ=America/Lima date +%F_%H%M)"
DESTINO="$AQUI/respaldos"
mkdir -p "$DESTINO"
chmod 700 "$DESTINO"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# LOS CONTEOS VAN ANTES que los volcados: si algo entra entre medio, el
# volcado tiene MÁS, nunca menos, y --probar lo acepta (>=).
paso "Conteos (para comprobar al restaurar)"
{
    echo "fecha=$FECHA"
    echo "comprobantes=$(psql_fac -tA -c 'SELECT count(*) FROM comprobantes')"
    echo "tenants=$(psql_fac -tA -c 'SELECT count(*) FROM tenants')"
    echo "empresas=$(psql_pla -tA -c 'SELECT count(*) FROM empresas')"
    echo "documentos=$(psql_pla -tA -c 'SELECT count(*) FROM documentos')"
} > "$TMP/conteos.txt"
sed 's/^/  /' "$TMP/conteos.txt"

paso "Bases"
"${DC[@]}" exec -T db-facturacion pg_dump -U facturacion_owner -d facturacion -Fc > "$TMP/facturacion.dump"
"${DC[@]}" exec -T db-plataforma  pg_dump -U postgres          -d plataforma  -Fc > "$TMP/plataforma.dump"
echo "  facturacion.dump $(du -h "$TMP/facturacion.dump" | cut -f1) · plataforma.dump $(du -h "$TMP/plataforma.dump" | cut -f1)"

paso "Almacén"
# 038 (QA, opción B′): los archivos están en Cloudflare R2. Se copian a otro
# bucket con «rclone copy» (nunca borra: si algo se borra en el origen, la
# copia lo conserva). Va aparte del .tar.gz, que solo lleva las bases.
ORIGEN_ALM="$(leer ALMACEN_RCLONE_ORIGEN .env.base 2>/dev/null || true)"
DESTINO_ALM="$(leer ALMACEN_RCLONE_DESTINO .env.base 2>/dev/null || true)"
if [ -n "$ORIGEN_ALM" ] && [ -n "$DESTINO_ALM" ]; then
    command -v rclone >/dev/null || falla "ALMACEN_RCLONE_ORIGEN está puesto pero rclone no está instalado."
    rclone copy "$ORIGEN_ALM" "$DESTINO_ALM" && echo "  archivos de $ORIGEN_ALM copiados a $DESTINO_ALM"
fi
almacen="$("${DC[@]}" ps -q almacen 2>/dev/null || true)"
if [ -n "$almacen" ]; then
    docker run --rm --volumes-from "$almacen" alpine:3.20 tar -C /data -cf - . > "$TMP/almacen.tar"
    echo "  almacen.tar $(du -h "$TMP/almacen.tar" | cut -f1)"
else
    echo "  sin contenedor «almacen» (¿R2?): el almacén lo replica el proveedor; no va en este archivo."
fi

ARCHIVO="$DESTINO/respaldo-$FECHA.tar.gz"
tar -czf "$ARCHIVO" -C "$TMP" .
chmod 600 "$ARCHIVO"
echo
echo "Respaldo: $ARCHIVO ($(du -h "$ARCHIVO" | cut -f1))"

paso "Retención: 7 diarios + 4 semanales"
hoy="$(date +%s)"
for f in "$DESTINO"/respaldo-*.tar.gz; do
    [ -e "$f" ] || continue
    dia="$(basename "$f" | sed -E 's/^respaldo-([0-9]{4}-[0-9]{2}-[0-9]{2})_.*/\1/')"
    t="$(date -d "$dia" +%s 2>/dev/null)" || continue
    edad=$(( (hoy - t) / 86400 ))
    domingo=$([ "$(date -d "$dia" +%u)" = "7" ] && echo si || echo no)
    if [ "$edad" -gt 28 ] || { [ "$edad" -gt 7 ] && [ "$domingo" = "no" ]; }; then
        rm -f "$f"; echo "  borrado $(basename "$f")"
    fi
done

DESTINO_REMOTO="$(leer RESPALDO_RCLONE_DESTINO .env.base 2>/dev/null || true)"
if [ -n "$DESTINO_REMOTO" ]; then
    paso "Copia fuera del servidor"
    command -v rclone >/dev/null || falla "RESPALDO_RCLONE_DESTINO está puesto pero rclone no está instalado."
    rclone copy "$ARCHIVO" "$DESTINO_REMOTO" && echo "  subido a $DESTINO_REMOTO"
else
    echo
    echo "AVISO: sin RESPALDO_RCLONE_DESTINO el respaldo solo está en este disco."
fi