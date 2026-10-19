# syntax=docker/dockerfile:1
# =============================================================================
# PLATAFORMA — el front (React) y la API (.NET 10) en una sola imagen: la API
# sirve el front desde wwwroot (UseStaticFiles + MapFallbackToFile).
#
# Contexto: la carpeta reyban_plataforma, la que tiene reyban_plataforma_service
# y reyban_plataforma_web (el compose lo hace). Lo que entra lo decide
# plataforma.Dockerfile.dockerignore.
# =============================================================================

# -------------------------------------------------------------------- el front
FROM node:22-bookworm-slim AS front
WORKDIR /web
COPY reyban_plataforma_web/package*.json ./
RUN if [ -f package-lock.json ]; then npm ci; else npm install; fi
COPY reyban_plataforma_web/ ./
# --outDir fuerza la salida aquí, diga lo que diga vite.config.
RUN npm run build -- --outDir /salida --emptyOutDir

# ---------------------------------------------------------------------- la API
FROM mcr.microsoft.com/dotnet/sdk:10.0 AS compilar
WORKDIR /src
COPY reyban_plataforma_service/ ./
RUN dotnet restore Plataforma.Api/Plataforma.Api.csproj --locked-mode \
 && dotnet publish Plataforma.Api/Plataforma.Api.csproj -c Release --no-restore -o /salida /p:UseAppHost=false

# ----------------------------------------------------------------- la imagen
FROM mcr.microsoft.com/dotnet/aspnet:10.0
RUN apt-get update \
 && apt-get install -y --no-install-recommends tzdata curl \
 && rm -rf /var/lib/apt/lists/*
ENV TZ=America/Lima \
    ASPNETCORE_ENVIRONMENT=Production \
    ASPNETCORE_URLS=http://+:8080
WORKDIR /app
# 038: los logs por día. La carpeta es del usuario de la app (el resto de /app no).
RUN mkdir -p /app/logs && chown $APP_UID /app/logs
COPY --from=compilar /salida ./
COPY --from=front /salida ./wwwroot/
USER $APP_UID
EXPOSE 8080
ENTRYPOINT ["dotnet", "Plataforma.Api.dll"]