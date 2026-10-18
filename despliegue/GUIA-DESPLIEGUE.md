# Guía de despliegue — paso a paso

Servicio de facturación + plataforma, en un solo servidor Ubuntu 24.04 con
Docker Compose. Es la sección 5 de `despliegue-pendientes.md` hecha comandos.
Todo lo de esta carpeta (`despliegue/`) está escrito y comprobado por partes
(abajo, «Qué se probó»), **pero nunca se ha levantado entero**: el primer
`docker compose build` es parte del día D.

**La regla que no se negocia:** el despliegue no está terminado hasta que un
respaldo se haya **restaurado** con éxito (paso 22).

---

## Qué hay en esta carpeta

| Archivo | Para qué |
|---|---|
| `docker-compose.produccion.yml` | Las piezas: 2 bases, almacén (y quien crea su bucket), API y Worker del servicio, plataforma, Caddy |
| `Caddyfile` | TLS automático; los 3 dominios; la regla del portal (`/portal`) |
| `servicio.Dockerfile` (+ `.dockerignore`) | Imágenes de la API y el Worker, **.NET 10**. Sustituye a los `Dockerfile.api` y `Dockerfile.worker` de la raíz, que siguen en .NET 8 y ya no se usan |
| `plataforma.Dockerfile` (+ `.dockerignore`) | El front (React) compilado dentro de la API de la plataforma (.NET 10) |
| `.env.ejemplo`, `.env.servicio.ejemplo`, `.env.plataforma.ejemplo` | Las plantillas, **sin un solo valor secreto** |
| `migrar.sh` | Aplica lo que falte, en orden; pone las contraseñas de los roles; **salta la semilla de la 002**; corre `verificar.sql` sin dejar datos |
| `respaldo.sh` | Las dos bases + el almacén, con fecha; 7 diarios + 4 semanales; copia fuera con rclone |
| `restaurar.sh` | `--probar`: restaura en un PostgreSQL aparte y compara conteos. `--de-verdad`: para el desastre |
| `.gitignore`, `.gitattributes` | Los `.env` nunca entran en git; los `.sh` siempre con LF |

## Las direcciones

| Dominio | Qué | Detrás |
|---|---|---|
| `api.reyban.pe` | API del servicio y su panel | `facturacion-api:8080` |
| `comprobantes.reyban.pe` | Portal del receptor | `facturacion-api:8080/portal/...` (reescrito) |
| `app.reyban.pe` | La plataforma (front + `/api`) | `plataforma:8080` |

Solo Caddy publica puertos (80 y 443). Las API creen la IP de
`X-Forwarded-For` **solo** si viene de Caddy (172.30.0.10, fija en el
compose): así el límite de intentos del portal ve la IP real del receptor y
nadie puede inventarse una.

---

## Fase 1 — En tu equipo, antes de contratar nada

1. **Construir las imágenes en tu PC** (Docker Desktop), desde la carpeta del servicio:
   ```powershell
   cd "D:\Reyban Consulting\facturacion electronica\facturacion_electronica_service\despliegue"
   Copy-Item .env.ejemplo .env
   # Rellena en .env CUALQUIER valor (p. ej. «x») en las contraseñas, MinIO y CORREO_TLS:
   # vacíos, docker compose se niega incluso a construir.
   New-Item .env.servicio, .env.plataforma -ItemType File
   docker compose -f docker-compose.produccion.yml build
   ```
   Tiene que terminar sin error. Si falla:
   - `--locked-mode`: falta un `packages.lock.json` en git, o no está al día. `dotnet restore` en tu PC y súbelo.
   - `COPY /src/xsd/`: la carpeta de esquemas no está en la raíz del servicio. Dime dónde está.
   - `npm run build`: el front no compila; arréglalo en desarrollo primero.
   - Si el almacén no queda «healthy», mira `docker compose logs almacen`; fija `IMAGEN_MINIO` a una versión que hayas probado.
   Después borra esos `.env` de prueba.
2. **Pruebas una última vez:** `dotnet test` en el servicio (125).
3. **Arquitectura:** si el servidor es ARM (Hetzner CAX), las imágenes se construyen **en el servidor** (paso 11), no se suben desde tu PC x86.

## Fase 2 — El servidor

4. Contratar: Ubuntu 24.04 LTS, 4 vCPU / 8 GB / 80 GB.
5. DNS: registros `A` de `api`, `comprobantes` y `app` hacia la IP. SPF, DKIM y DMARC del correo (`despliegue-pendientes.md` §3.1). **Esperar a que resuelvan** antes del paso 14.
6. Endurecer:
   ```bash
   adduser reyban && usermod -aG sudo reyban
   # en /etc/ssh/sshd_config:  PermitRootLogin no  ·  PasswordAuthentication no
   sudo ufw allow 22,80,443/tcp && sudo ufw enable
   sudo apt install -y unattended-upgrades
   ```
7. Docker: `curl -fsSL https://get.docker.com | sh` y `sudo usermod -aG docker reyban`.

## Fase 3 — Levantar

8. El código, **con la misma estructura de carpetas que en tu PC**:
   ```bash
   sudo mkdir -p /opt/reyban && sudo chown reyban /opt/reyban && cd /opt/reyban
   mkdir -p "facturacion electronica" reyban_plataforma
   git clone <repo del servicio>    "facturacion electronica/facturacion_electronica_service"
   git clone <repo de la plataforma> reyban_plataforma/reyban_plataforma_service
   git clone <repo del front>        reyban_plataforma/reyban_plataforma_web
   cd "facturacion electronica/facturacion_electronica_service/despliegue"
   ```
9. Los tres `.env`, **escritos en el servidor** (nunca copiados de tu PC, nunca en git):
   ```bash
   cp .env.ejemplo .env && cp .env.servicio.ejemplo .env.servicio && cp .env.plataforma.ejemplo .env.plataforma
   chmod 600 .env .env.servicio .env.plataforma
   nano .env    # y los otros dos
   ```
   Todo nuevo: contraseñas de base, de roles, de MinIO, las dos llaves maestras (`openssl rand -base64 32`), clave de alta, correo. **Anótalo en el gestor de contraseñas ahora.**
10. Bases arriba: `docker compose -f docker-compose.produccion.yml up -d db-facturacion db-plataforma`
11. Construir: `docker compose -f docker-compose.produccion.yml build`
12. Migrar: `./migrar.sh` → tiene que terminar en `TODAS LAS COMPROBACIONES PASARON`.
13. Todo arriba: `docker compose -f docker-compose.produccion.yml up -d` y mirar `docker compose -f docker-compose.produccion.yml logs -f --tail 100`.
    - El almacén: `almacen-inicial` crea el bucket `comprobantes` (con versionado) y termina; la API lo comprueba al arrancar («Almacén S3 listo»).
    - El log del Worker NO debe decir «Validacion XSD DESACTIVADA».
14. Comprobar: `https://api.reyban.pe/health` con candado válido; `https://comprobantes.reyban.pe/{empresa}` abre el portal; `https://app.reyban.pe` abre la plataforma.

## Fase 4 — Ponerlo en marcha

15. Panel del servicio: cambiar la contraseña del administrador. Emitir una **clave de alta nueva** y ponerla en `.env.plataforma` (`FACTURACION_CLAVE_ALTA`); `docker compose ... up -d plataforma`.
16. Plataforma: entrar como super administrador y cambiar su contraseña.
17. Primera empresa, su certificado (por el panel), SUNAT en **beta**, un comprobante de prueba aceptado y su correo.
18. Pasar a producción y emitir **un comprobante real y pequeño**, mirando el log.
19. Vigilancia SUNAT → «Esquemas XSD»: subir los 4 de SUNAT.

## Fase 5 — Lo que lo deja terminado de verdad

20. Cron del respaldo (el servidor está en UTC; 09:30 UTC = 04:30 en Lima, después de la prueba de madrugada):
    ```bash
    crontab -e
    30 9 * * *  "/opt/reyban/facturacion electronica/facturacion_electronica_service/despliegue/respaldo.sh" >> /home/reyban/respaldo.log 2>&1
    ```
21. Un respaldo a mano: `./respaldo.sh`
    Para un desastre en un servidor NUEVO: levanta las bases, `./restaurar.sh --de-verdad <archivo> --borra-lo-actual` (crea los roles que faltan) y después `./migrar.sh` (pone sus contraseñas).
22. **Restaurarlo:** `./restaurar.sh --probar respaldos/respaldo-<fecha>.tar.gz` → `RESTAURACIÓN PROBADA`. Sin esto no está hecho.
23. Copia fuera: `rclone config` (R2 o similar) y `RESPALDO_RCLONE_DESTINO` en `.env`.
24. En el gestor de contraseñas: las dos llaves maestras, las contraseñas de base y de roles, MinIO, correo, acceso SSH. **Los respaldos no llevan las llaves, a propósito**: sin ellas, los certificados del respaldo no sirven.
25. Reiniciar el servidor entero (`sudo reboot`) y comprobar que todo vuelve solo.

---

## Qué se probó y qué no (16 de octubre)

| | |
|---|---|
| `docker compose config` | Válido; contextos y Dockerfiles resuelven a las carpetas correctas |
| `caddy validate` | «Valid configuration» con los tres dominios |
| `shellcheck` | Sin avisos en los cuatro `.sh` |
| `migrar.sh` | Corrido de punta a punta contra bases de prueba: las 27 de la plataforma + `verificar.sql` (29 comprobaciones, sin dejar datos), dos veces seguidas; la 002 del servicio entra **sin** su clave sembrada (0 claves) |
| Restaurar | Los volcados de las dos bases se restauran en un PostgreSQL vacío con los roles creados a mano, como hace `restaurar.sh --probar` |
| La IP real detrás de Caddy | Con `PROXY_IP_CONFIABLE`, la API ve la IP de `X-Forwarded-For` y el esquema https; sin ella, la ignora |
| **Sin probar** | Construir las imágenes (aquí no se puede bajar de Docker Hub), levantar el compose entero, `respaldo.sh`/`restaurar.sh` contra contenedores de verdad. Es la Fase 1 |