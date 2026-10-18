-- =============================================================================
-- 034 — UN ROL DE BASE PROPIO PARA LA RUTA DE ALTA (punto 23)
--
-- La ruta POST /alta/emisores (la que usa la plataforma con su clave alt_)
-- creaba el emisor con el rol de OPERADOR, que ve y cambia todas las empresas
-- y todos sus comprobantes. Lo estrecho de la alt_ lo garantizaba solo el
-- código (RepositorioAltas).
--
-- Ahora esa ruta entra con `facturacion_alta`, que en la base SOLO puede:
--
--   claves_alta      leer y anotar su uso (y el aviso del tope)
--   tenants          leer, crear y abandonar un alta a medias
--   api_keys         crear la fac_ del emisor nuevo; revocar la de un alta abandonada
--   webhooks         crear el del emisor nuevo; apagar el de un alta abandonada
--   webhook_cambios  dejar el rastro
--
-- Nada de comprobantes, certificados, usuarios del panel ni nada más. Si un
-- fallo en la ruta de alta dejara correr una consulta que no toca, la base la
-- rechaza.
--
-- BYPASSRLS porque el alta tiene que ver si el RUC ya existe en CUALQUIER
-- empresa y contar las altas del día; con los permisos de arriba eso no le
-- abre nada más.
--
-- LA CONTRASEÑA NO VA AQUÍ (nada de secretos en una migración). Después de
-- aplicarla:
--
--     ALTER ROLE facturacion_alta PASSWORD '<una nueva, larga, al azar>';
--
-- y en el .env del servicio:  FACTURACION_ALTA_PASSWORD=<la misma>
--
-- Sin esa variable, en desarrollo la ruta sigue con el operador (y lo dice en
-- el log al arrancar); en producción la API no arranca.
--
-- Se puede correr dos veces: no cambia nada la segunda.
-- =============================================================================

BEGIN;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'facturacion_alta') THEN
        CREATE ROLE facturacion_alta LOGIN BYPASSRLS;
    END IF;
END $$;

ALTER ROLE facturacion_alta LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION BYPASSRLS;

-- Desde cero: si alguien le dio algo más a mano, se le quita.
REVOKE ALL ON ALL TABLES    IN SCHEMA public FROM facturacion_alta;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM facturacion_alta;

GRANT USAGE ON SCHEMA public TO facturacion_alta;

GRANT SELECT, UPDATE (ultimo_uso, tope_avisado_en) ON claves_alta TO facturacion_alta;

-- Solo las columnas que el alta mira: NO las claves cifradas (SOL, GRE).
GRANT SELECT (id, ruc, estado_alta, creado_por_clave_alta, creado_en, activo) ON tenants TO facturacion_alta;
GRANT INSERT ON tenants TO facturacion_alta;
GRANT UPDATE (estado_alta, activo, abandonada_en) ON tenants TO facturacion_alta;

GRANT SELECT (id, tenant_id, activo), INSERT ON api_keys TO facturacion_alta;
GRANT UPDATE (activo, revocado_en) ON api_keys TO facturacion_alta;

GRANT SELECT (id, tenant_id, url, activo), INSERT ON webhooks TO facturacion_alta;
GRANT UPDATE (activo) ON webhooks TO facturacion_alta;

GRANT INSERT ON webhook_cambios TO facturacion_alta;

DO $$
DECLARE s regclass;
BEGIN
    FOR s IN SELECT pg_get_serial_sequence(t, c)::regclass
               FROM (VALUES ('webhook_cambios', 'id')) v(t, c)
              WHERE pg_get_serial_sequence(t, c) IS NOT NULL
    LOOP
        EXECUTE format('GRANT USAGE ON SEQUENCE %s TO facturacion_alta', s);
    END LOOP;
END $$;

DO $$ BEGIN RAISE NOTICE '034: rol facturacion_alta listo. Falta ponerle contrasena (ver arriba).'; END $$;

COMMIT;