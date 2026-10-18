# syntax=docker/dockerfile:1
# =============================================================================
# SERVICIO DE FACTURACIÓN — una imagen para la API y otra para el Worker
# (.NET 10). Se construyen desde la RAÍZ del servicio (el compose lo hace):
#
#   docker compose -f despliegue/docker-compose.produccion.yml build facturacion-api facturacion-worker
#
# Sustituye a Dockerfile.api y Dockerfile.worker de la raíz, que siguen en
# .NET 8 y no se usan más.
#
# Lo que entra en el contexto lo decide servicio.Dockerfile.dockerignore (al
# lado de este archivo): nada de .env, .pfx, clave.txt, bin/obj de Windows ni
# migraciones.
# =============================================================================

FROM mcr.microsoft.com/dotnet/sdk:10.0 AS compilar
WORKDIR /src
COPY . .
# Restauración con los archivos de bloqueo (packages.lock.json): las mismas
# versiones exactas que en desarrollo, o falla.
RUN dotnet restore Facturacion.Api/Facturacion.Api.csproj --locked-mode \
 && dotnet restore Facturacion.Worker/Facturacion.Worker.csproj --locked-mode \
 && dotnet publish Facturacion.Api/Facturacion.Api.csproj       -c Release --no-restore -o /salida/api    /p:UseAppHost=false \
 && dotnet publish Facturacion.Worker/Facturacion.Worker.csproj -c Release --no-restore -o /salida/worker /p:UseAppHost=false

# ----------------------------------------------------------------- base común
FROM mcr.microsoft.com/dotnet/aspnet:10.0 AS base
# tzdata: todo razona en hora de Lima (sin ella el proceso no arranca, a
# propósito). Fuentes: QuestPDF las necesita, y sin ellas el PDF falla el día
# que alguien lo pide. curl: el healthcheck.
RUN apt-get update \
 && apt-get install -y --no-install-recommends tzdata fontconfig fonts-dejavu-core fonts-liberation curl \
 && rm -rf /var/lib/apt/lists/*
ENV TZ=America/Lima \
    ASPNETCORE_ENVIRONMENT=Production \
    DOTNET_ENVIRONMENT=Production
WORKDIR /app

# ------------------------------------------------------------------------ API
FROM base AS api
COPY --from=compilar /salida/api ./
ENV ASPNETCORE_URLS=http://+:8080
USER $APP_UID
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=5s --start-period=40s --retries=3 \
  CMD curl -fsS http://localhost:8080/health || exit 1
ENTRYPOINT ["dotnet", "Facturacion.Api.dll"]

# --------------------------------------------------------------------- WORKER
FROM base AS worker
COPY --from=compilar /salida/worker ./
# Los esquemas XSD que vienen con el código (los 5 de UBL). Los 4 de SUNAT
# los sube el panel («Esquemas XSD») y el Worker los copia aquí cada 2
# minutos: por eso la carpeta es SUYA (escribible) y el resto de /app no.
COPY --from=compilar /src/xsd/ ./xsd/
RUN chown -R $APP_UID /app/xsd
USER $APP_UID
ENTRYPOINT ["dotnet", "Facturacion.Worker.dll"]