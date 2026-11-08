#!/usr/bin/env bash
# =============================================================================
# ROTAR LAS CONTRASEÑAS DE LA BASE — paso 1 de 2, en el SERVIDOR DE BASE.
#
#   bash rotar-claves-base.sh
#
# Genera contraseñas NUEVAS para los cuatro roles con los que entra la
# aplicación (facturacion_app, facturacion_operador, facturacion_alta y
# plataforma_app), las escribe en .env.base y corre migrar.sh, que se las pone
# a los roles. Al final las muestra EN ESTA CONSOLA para copiarlas al
# servidor de aplicación (paso 2: rotar-claves-app.sh).
#
# Mientras no hagas el paso 2, la aplicación no puede entrar a la base: hazlo
# enseguida (es un minuto).
#
# Nunca las pegues en un chat ni en un correo. No se guardan en ningún otro
# archivo.
# =============================================================================
# shellcheck source=comun.sh
source "$(dirname "$0")/comun.sh"

ENV_BASE="$AQUI/.env.base"
[ -f "$ENV_BASE" ] || falla "No existe $ENV_BASE."

# 32 letras y números: sin símbolos que rompan una cadena de conexión.
nueva() { openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 32; }

# Reemplaza (o agrega) NOMBRE=valor en un .env sin tocar lo demás.
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

paso "Contraseñas nuevas para los roles de la aplicación"
P_APP="$(nueva)"; P_OPE="$(nueva)"; P_ALTA="$(nueva)"; P_PLA="$(nueva)"
for v in P_APP P_OPE P_ALTA P_PLA; do [ "${#v}" -gt 0 ] && [ "$(printf '%s' "${!v}" | wc -c)" -eq 32 ] || falla "No se pudo generar una contraseña."; done
poner FACTURACION_APP_PASSWORD      "$P_APP"  "$ENV_BASE"
poner FACTURACION_OPERADOR_PASSWORD "$P_OPE"  "$ENV_BASE"
poner FACTURACION_ALTA_PASSWORD     "$P_ALTA" "$ENV_BASE"
poner PLATAFORMA_APP_PASSWORD       "$P_PLA"  "$ENV_BASE"
echo "  .env.base actualizado."

if [ "${ROTAR_SIN_MIGRAR:-}" != "1" ]; then
    paso "Poniéndolas en la base (migrar.sh)"
    bash "$AQUI/migrar.sh"
fi

cat <<FIN

==============================================================================
 PASO 2 — en el SERVIDOR DE APLICACIÓN, en la carpeta despliegue:

     bash rotar-claves-app.sh

 Te pedirá estas cuatro, una por una (al pegarlas no se ven, es normal):

   facturacion_app       $P_APP
   facturacion_operador  $P_OPE
   facturacion_alta      $P_ALTA
   plataforma_app        $P_PLA

 Cuando termine, limpia esta consola:  clear && history -c
==============================================================================
FIN