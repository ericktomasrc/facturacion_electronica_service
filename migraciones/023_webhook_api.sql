-- ===========================================================================
-- 023 — El webhook de la API: la clave fac_ registra el suyo
--
-- POR QUE HACE FALTA (alta-empresa-diseno.md, parte A):
--
-- Hasta hoy un webhook solo se registraba desde el panel, y el secreto whsec_
-- se copiaba a mano a la plataforma. Desde ahora la plataforma lo registra
-- sola con POST /v1/webhook, usando la clave de la empresa.
--
-- UNO POR EMPRESA, Y SE ACTUALIZA EN LA MISMA FILA. El disparador
-- encolar_evento_comprobante crea una entrega por cada webhook activo: si
-- cada rotacion creara uno nuevo, cada factura se avisaria dos, tres, cuatro
-- veces. Por eso:
--
--   origen               'panel' (los de siempre) o 'api' (los de /v1/webhook)
--   ux_webhooks_api_...  como mucho UN webhook 'api' activo por empresa
--   secreto_cambiado_en  cuando se genero el secreto vigente
--
-- webhook_cambios: quien cambio que y cuando. URL de antes y de despues,
-- y el prefijo de la clave que lo hizo (el mismo que ensena el panel).
-- NUNCA el secreto.
--
-- NADA SE BORRA (punto 18): se quita DELETE y TRUNCATE sobre webhooks,
-- webhook_entregas y webhook_cambios a todos los roles de la aplicacion. El
-- boton "Eliminar" del panel desaparece; queda "Desactivar".
--
-- Idempotente: se puede aplicar dos veces sin error.
-- ===========================================================================

BEGIN;

-- --- webhooks: origen y fecha del secreto ---------------------------------

ALTER TABLE webhooks
    ADD COLUMN IF NOT EXISTS origen text NOT NULL DEFAULT 'panel';

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'ck_webhooks_origen'
                      AND conrelid = 'webhooks'::regclass) THEN
        ALTER TABLE webhooks
            ADD CONSTRAINT ck_webhooks_origen CHECK (origen IN ('panel', 'api'));
    END IF;
END
$$;

ALTER TABLE webhooks
    ADD COLUMN IF NOT EXISTS secreto_cambiado_en timestamptz;

-- Los que ya existen: su secreto es el de su creacion.
UPDATE webhooks SET secreto_cambiado_en = creado_en
 WHERE secreto_cambiado_en IS NULL;

ALTER TABLE webhooks ALTER COLUMN secreto_cambiado_en SET DEFAULT now();
ALTER TABLE webhooks ALTER COLUMN secreto_cambiado_en SET NOT NULL;

-- Uno solo de la API, activo, por empresa. Los desactivados no cuentan:
-- quedan como historial.
CREATE UNIQUE INDEX IF NOT EXISTS ux_webhooks_api_por_tenant
    ON webhooks (tenant_id)
    WHERE origen = 'api' AND activo;


-- --- webhook_cambios -------------------------------------------------------

CREATE TABLE IF NOT EXISTS webhook_cambios (
    id              bigserial   PRIMARY KEY,
    webhook_id      uuid        NOT NULL REFERENCES webhooks(id) ON DELETE RESTRICT,
    tenant_id       uuid        NOT NULL REFERENCES tenants(id)  ON DELETE RESTRICT,

    -- alta:        la API lo creo
    -- rotacion:    la API le cambio el secreto (y quiza la URL)
    -- activado / desactivado: desde el panel
    accion          text        NOT NULL,

    url_antes       text,
    url_despues     text        NOT NULL,

    -- 'api' o 'panel'
    hecho_desde     text        NOT NULL,

    -- Prefijo de la clave fac_ que hizo el cambio: sus primeros 20
    -- caracteres, los mismos de api_keys.prefijo, que el panel ya ensena en
    -- la pestana Claves de acceso. Sirve para encontrarla y revocarla.
    prefijo_clave   text,

    -- Los cambios hechos desde el panel no llevan prefijo: quien los hizo esta
    -- en la bitacora del panel (auditoria), con su correo, ruta y hora.

    creado_en       timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT ck_webhook_cambios_accion
        CHECK (accion IN ('alta', 'rotacion', 'activado', 'desactivado')),
    CONSTRAINT ck_webhook_cambios_desde
        CHECK (hecho_desde IN ('api', 'panel')),
    CONSTRAINT ck_webhook_cambios_prefijo
        CHECK (prefijo_clave IS NULL OR length(prefijo_clave) <= 20)
);

CREATE INDEX IF NOT EXISTS ix_webhook_cambios_tenant
    ON webhook_cambios (tenant_id, creado_en DESC);

ALTER TABLE webhook_cambios ENABLE ROW LEVEL SECURITY;
ALTER TABLE webhook_cambios FORCE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS aislamiento_tenant ON webhook_cambios;

CREATE POLICY aislamiento_tenant ON webhook_cambios
    USING (tenant_id = app_tenant_actual())
    WITH CHECK (tenant_id = app_tenant_actual());

-- Solo se escribe y se lee: ni UPDATE ni DELETE. Es una bitacora.
GRANT SELECT, INSERT ON webhook_cambios TO facturacion_app;
GRANT SELECT, INSERT ON webhook_cambios TO facturacion_operador;
GRANT USAGE, SELECT ON SEQUENCE webhook_cambios_id_seq TO facturacion_app;
GRANT USAGE, SELECT ON SEQUENCE webhook_cambios_id_seq TO facturacion_operador;


-- --- Nada se borra --------------------------------------------------------
--
-- La 005 dio ALL al operador, que incluye DELETE y TRUNCATE. El unico que
-- los usaba era "Eliminar webhook", que desaparece en esta misma entrega.

REVOKE DELETE, TRUNCATE ON webhooks, webhook_entregas, webhook_cambios
    FROM facturacion_operador, facturacion_app;


-- Sin tildes: PowerShell 5.1 manda este archivo a psql en ASCII.
COMMENT ON COLUMN webhooks.origen IS
    'panel: registrado a mano en el panel. api: registrado con POST /v1/webhook por la clave de la empresa; uno activo como mucho.';

COMMENT ON TABLE webhook_cambios IS
    'Quien cambio cada webhook y cuando: URL antes y despues, prefijo de la clave. Nunca el secreto.';

COMMIT;