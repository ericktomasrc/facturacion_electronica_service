# Rotar las claves (QA)

Las claves nuevas nacen **en el servidor** y nunca pasan por el chat, un
correo ni un `.zip`.

## 1. Contraseñas de la base (los dos scripts)

1. **Servidor de base** (`qa-base`), en la carpeta `despliegue`:

       git pull
       bash rotar-claves-base.sh

   Cambia las 4 contraseñas de los roles (facturacion_app, facturacion_operador,
   facturacion_alta, plataforma_app) y te las muestra en esa consola.

2. **Servidor de aplicación** (`qa-app`), en la carpeta `despliegue`, enseguida:

       git pull
       bash rotar-claves-app.sh

   Pega las 4 cuando las pida (no se ven al pegarlas). Escribe
   `.env.servicio` y la cadena de `.env.plataforma` y vuelve a levantar la
   plataforma, la API y el worker.

3. En las dos consolas: `clear && history -c`.

Entre el paso 1 y el 2 la aplicación no puede entrar a la base (un minuto).
Si algo falla, vuelve a correr los dos pasos: se generan otras nuevas.

## 2. Las que se cambian en la página de cada proveedor

Cada una: generas la nueva en el proveedor, la pegas en el `.env` del servidor
con `nano`, `up -d` del contenedor, y luego borras la vieja en el proveedor.

| Clave | Dónde se genera la nueva | Dónde se pega |
|---|---|---|
| Contraseña de aplicación de Gmail | myaccount.google.com › Seguridad › Contraseñas de aplicaciones | `.env.servicio` (MAIL_CLAVE) y `.env.plataforma` (MAIL_PASSWORD) |
| GOOGLE_CLIENT_SECRET | console.cloud.google.com › Credenciales › tu cliente OAuth › «Agregar secreto» | `.env.plataforma` |
| DECOLECTA_TOKEN | panel de Decolecta › API keys | `.env.plataforma` |
| TURNSTILE_SECRET | dash.cloudflare.com › Turnstile › tu sitio › «Rotar clave secreta» | `.env.plataforma` |
| Culqi llave secreta de prueba | panel de Culqi › Desarrollo › API Keys › «Renovar» | `.env.plataforma` |
| R2 de los respaldos (si quieres) | dash.cloudflare.com › R2 › Administrar tokens de API | qa-base: `rclone config` (no es un .env) |

## 3. Las que NO se rotan en QA

- **FACTURACION_LLAVE_MAESTRA** y **PLATAFORMA_LLAVE_MAESTRA**: con ellas
  están cifrados los certificados, las claves SOL, el 2FA y las llaves de API.
  Si se cambian, todo eso deja de abrirse. En **producción** se empieza con
  llaves nuevas desde el día uno (nunca las de QA ni las de local).
- La contraseña de `postgres` (dueño de la base): solo entra desde dentro del
  servidor; no viaja a la aplicación.

## 4. Producción

Todas nuevas, generadas en ese servidor. Ninguna se copia de QA ni de local.