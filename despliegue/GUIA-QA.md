# Guía de QA — opción B′ (dos servidores), paso a paso

**Desde el 19 de octubre de 2026 esta es la guía.** `GUIA-DESPLIEGUE.md` y
`docker-compose.produccion.yml` (todo en un servidor, con MinIO) quedan como
referencia: los scripts `migrar.sh`, `respaldo.sh` y `restaurar.sh` ya
trabajan con el servidor de base de esta guía.

```
 Internet ──► Caddy (443) ─┬─► plataforma (API + front)      SERVIDOR DE APLICACIÓN
                           └─► facturacion-api / worker       Ubuntu 24.04 · 4 GB
                                    │      │
                    red privada ────┘      └──► Cloudflare R2 (XML, CDR, PDF, logos)
                         ▼
                 db-facturacion (5432) · db-plataforma (5433)  SERVIDOR DE BASE
                 solo en la IP privada                         Ubuntu 24.04 · 2 GB
```

**Regla que no se negocia:** QA no está listo hasta que un respaldo se haya
**restaurado** con éxito (paso 24).

**Los secretos:** se escriben **en cada servidor**, con `nano`, nunca en el
chat, nunca en git, nunca en un `.zip`. Se generan con:

```bash
openssl rand -base64 32 | tr -d '/+=' | cut -c1-32     # contraseñas
openssl rand -base64 32                                 # llaves maestras
```

---

## Qué archivo va dónde

| Archivo (en `despliegue/`) | Servidor | Para qué |
|---|---|---|
| `compose.base.yml` + `.env.base` | Base | Las dos bases, solo en la IP privada |
| `migrar.sh`, `respaldo.sh`, `restaurar.sh`, `comun.sh` | Base | Migraciones, respaldo diario, restaurar |
| `compose.aplicacion.yml` + `.env.aplicacion` | Aplicación | Caddy, plataforma, servicio |
| `.env.servicio`, `.env.plataforma` | Aplicación | Los secretos de cada aplicación |
| `Caddyfile.qa` + `qa_usuarios.caddy` | Aplicación | TLS, dominios y la protección de QA |

Las contraseñas de los **roles** (`FACTURACION_APP_PASSWORD`, etc.) van en los
dos servidores y tienen que ser **iguales**: la base las pone (`migrar.sh`) y la
aplicación las usa.

---

## Fase 1 — Cuentas y dominio (antes de crear servidores)

1. **Proveedor** (Vultr recomendado; Lightsail como plan B). Cuenta con segundo
   factor. Elegir **una región** sudamericana y usarla para todo.
2. **Cloudflare:** el dominio pasa a Cloudflare (DNS).
   - R2 → crear el bucket `reyban-comprobantes-qa` y otro `reyban-respaldos-qa`.
   - R2 → *Manage API tokens* → un token con lectura/escritura **solo** en esos
     dos buckets. Anotar el *Access Key ID*, el *Secret* y el ID de cuenta.
3. **Correo** con remitente propio (SPF, DKIM y DMARC del proveedor elegido).

## Fase 2 — Los dos servidores

4. Crear la **red privada** (VPC) en la región elegida.
5. Crear el **servidor de base**: Ubuntu 24.04, 2 GB, en esa red privada.
   Activar las **instantáneas automáticas** del proveedor.
6. Crear el **servidor de aplicación**: Ubuntu 24.04, 4 GB, misma red privada.
7. En **los dos**, endurecer (como usuario con sudo, nunca root):
   ```bash
   sudo adduser reyban && sudo usermod -aG sudo reyban
   # /etc/ssh/sshd_config:  PermitRootLogin no  ·  PasswordAuthentication no
   sudo systemctl restart ssh
   sudo apt update && sudo apt install -y unattended-upgrades rclone
   curl -fsSL https://get.docker.com | sudo sh && sudo usermod -aG docker reyban
   ```
8. Firewall:
   - **Base:** `sudo ufw allow from <TU-IP>/32 to any port 22 && sudo ufw enable`.
     Nada más: las bases solo escuchan en la IP privada.
   - Si tu IP de casa cambia y SSH deja de entrar, se entra por la consola web
     del proveedor y se actualiza la regla (`sudo ufw allow from <IP-NUEVA>/32 to any port 22`).
   - **Aplicación:** `sudo ufw allow from <TU-IP>/32 to any port 22 && sudo ufw allow 80,443/tcp && sudo ufw enable`.
9. DNS en Cloudflare, registros **A** (nube gris, «solo DNS») hacia la IP
   **pública** del servidor de aplicación: `app.qa`, `api.qa`, `comprobantes.qa`.

## Fase 3 — El código en los servidores

10. En los dos, la **misma estructura de carpetas** que en tu PC:
    ```bash
    sudo mkdir -p /opt/reyban && sudo chown reyban /opt/reyban && cd /opt/reyban
    mkdir -p "facturacion electronica" reyban_plataforma
    # el código: git clone de tus repositorios (o lo subimos juntos, sin .env ni .pfx)
    ```

## Fase 4 — El servidor de base

11. `cd "/opt/reyban/facturacion electronica/facturacion_electronica_service/despliegue"`
12. `cp .env.base.ejemplo .env.base && chmod 600 .env.base && nano .env.base`
    (IP privada de este servidor, contraseñas nuevas, destino del respaldo).
13. `docker compose -f compose.base.yml --env-file .env.base up -d`
14. `./migrar.sh` → tiene que terminar en **TODAS LAS COMPROBACIONES PASARON**.
15. `rclone config` → un remoto `r2` (tipo S3, proveedor Cloudflare, con el token de R2).
16. Respaldo diario (09:30 UTC = 04:30 Lima, después de la prueba de madrugada):
    ```bash
    crontab -e
    30 9 * * *  "/opt/reyban/facturacion electronica/facturacion_electronica_service/despliegue/respaldo.sh" >> /home/reyban/respaldo.log 2>&1
    ```

## Fase 5 — El servidor de aplicación

17. `cd "/opt/reyban/facturacion electronica/facturacion_electronica_service/despliegue"`
18. Los tres archivos de secretos:
    ```bash
    cp .env.aplicacion.ejemplo .env.aplicacion
    cp .env.servicio.qa.ejemplo .env.servicio
    cp .env.plataforma.qa.ejemplo .env.plataforma
    chmod 600 .env.aplicacion .env.servicio .env.plataforma
    nano .env.aplicacion   # y los otros dos
    ```
19. El usuario de la protección de QA (la contraseña no queda escrita en claro):
    ```bash
    docker run --rm caddy:2.8-alpine caddy hash-password    # escribe la contraseña dos veces
    echo 'qa <el hash que salió>' > qa_usuarios.caddy && chmod 600 qa_usuarios.caddy
    ```
20. Construir y arrancar:
    ```bash
    docker compose -f compose.aplicacion.yml --env-file .env.aplicacion build
    docker compose -f compose.aplicacion.yml --env-file .env.aplicacion up -d
    docker compose -f compose.aplicacion.yml --env-file .env.aplicacion logs -f --tail 100
    ```
    En los logs: «Base de datos lista · 37 migraciones», «Almacén S3 listo», y el
    Worker sin «Validacion XSD DESACTIVADA».
21. Comprobar desde fuera:
    - `https://api.qa…/health` → 200 con candado válido.
    - `https://app.qa…` desde tu IP abre; desde el celular con datos pide usuario y contraseña.
    - `https://comprobantes.qa…/{empresa}` abre el portal sin contraseña.

## Fase 6 — Ponerlo en marcha

22. Panel del servicio: entrar, segundo factor, emitir una **clave de alta nueva**
    → `FACTURACION_CLAVE_ALTA` en `.env.plataforma` →
    `docker compose -f compose.aplicacion.yml --env-file .env.aplicacion up -d plataforma`.
23. Plataforma: entrar como super administrador (contraseña nueva y segundo
    factor), crear la empresa de prueba en **beta**, emitir y ver el CDR
    ACEPTADO y el correo en la bandeja de entrada (no spam).

## Fase 7 — Lo que lo deja terminado de verdad

24. En el servidor de base: `./respaldo.sh` y después
    `./restaurar.sh --probar respaldos/respaldo-<fecha>.tar.gz` → **RESTAURACIÓN PROBADA**.
25. Reiniciar los dos servidores (`sudo reboot`) y comprobar que todo vuelve solo.
26. En el gestor de contraseñas: las dos llaves maestras, las contraseñas de
    base y de roles, el token de R2, el correo, el usuario de QA, el acceso SSH.
27. Solo entonces: la primera empresa real, un comprobante pequeño, mirando el log.

---

## Para leer los logs por día

```bash
cd "/opt/reyban/facturacion electronica/facturacion_electronica_service/despliegue"
docker compose -f compose.aplicacion.yml --env-file .env.aplicacion exec plataforma ls /app/logs
docker compose -f compose.aplicacion.yml --env-file .env.aplicacion exec plataforma tail -n 100 /app/logs/$(TZ=America/Lima date +%F)/plataforma-api.log
docker compose -f compose.aplicacion.yml --env-file .env.aplicacion exec facturacion-api tail -n 100 /app/logs/$(TZ=America/Lima date +%F)/servicio-worker.log
```

## Si el servidor de base se pierde

Servidor nuevo (Fase 2 y 4 hasta el paso 13), luego
`./restaurar.sh --de-verdad <respaldo> --borra-lo-actual` y `./migrar.sh`.
Antes, en el servidor de aplicación, `docker compose ... stop` para que nadie
escriba mientras tanto.

## De QA a producción

Mismo kit, otros dominios y secretos nuevos; en `Caddyfile.qa` se quitan las dos
líneas `import protegido_qa`, y en `.env.plataforma` se pone
`PLATAFORMA_SUNAT=real`.