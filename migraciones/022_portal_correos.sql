-- ===========================================================================
-- 022 — El correo de entrega del portal
--
-- POR QUÉ HACE FALTA:
--
-- Cuando SUNAT acepta un comprobante que trae correo del cliente
-- (comprobantes.correo_receptor, migración 019), el servicio le manda un
-- correo con el PDF adjunto y un enlace de 400 días al portal.
--
-- Igual que los webhooks, se hace con una COLA: un disparador mete una fila
-- aquí en el mismo instante en que el comprobante pasa a aceptado, y un
-- proceso aparte la envía. Mandarlo desde la petición no vale: el correo
-- tarda, falla, y no puede retrasar ni romper la respuesta de SUNAT.
--
--
-- UNA FILA POR COMPROBANTE, NUNCA DOS (único por comprobante_id). Si el
-- estado pasara dos veces por aceptado, el cliente no recibe dos correos.
--
-- SOLO SE ENCOLA SI LA EMPRESA ESTÁ LISTA: con dirección del portal
-- (identificador) y correo de respuesta. Sin lo primero el enlace no lleva a
-- ninguna parte; sin lo segundo, las respuestas del cliente se perderían.
--
-- CON RLS, como webhook_entregas: guarda el correo del cliente, que es un
-- dato suyo. El disparador corre dentro de la sesión de la empresa, así que
-- la fila que mete es de esa empresa. Quien envía usa el rol de operador.
--
-- NADA SE BORRA: no hay DELETE para nadie.
-- ===========================================================================

BEGIN;

CREATE TABLE IF NOT EXISTS portal_correos (
    id                  uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id           uuid        NOT NULL REFERENCES tenants(id)        ON DELETE RESTRICT,
    comprobante_id      uuid        NOT NULL REFERENCES comprobantes(id)   ON DELETE RESTRICT,
    para                text        NOT NULL,
    estado              text        NOT NULL DEFAULT 'PENDIENTE',
    intentos            smallint    NOT NULL DEFAULT 0,
    proximo_intento_en  timestamptz,
    ultimo_error        text,
    enviado_en          timestamptz,
    acceso_id           uuid        REFERENCES portal_accesos(id)          ON DELETE RESTRICT,
    pdf_adjunto         boolean,
    creado_en           timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT ux_portal_correos_comprobante UNIQUE (comprobante_id),
    CONSTRAINT ck_portal_correos_estado
        CHECK (estado IN ('PENDIENTE', 'ENVIADO', 'AGOTADO', 'OMITIDO')),
    CONSTRAINT ck_portal_correos_enviado
        CHECK ((estado = 'ENVIADO') = (enviado_en IS NOT NULL))
);

CREATE INDEX IF NOT EXISTS ix_portal_correos_pendientes
    ON portal_correos (proximo_intento_en NULLS FIRST, creado_en)
    WHERE estado = 'PENDIENTE';

ALTER TABLE portal_correos ENABLE ROW LEVEL SECURITY;
ALTER TABLE portal_correos FORCE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS aislamiento_tenant ON portal_correos;
CREATE POLICY aislamiento_tenant ON portal_correos
    USING (tenant_id = app_tenant_actual())
    WITH CHECK (tenant_id = app_tenant_actual());

-- La aplicación solo mete filas (desde el disparador). El operador, que se
-- salta RLS, las lee y las actualiza al enviar.
GRANT SELECT, INSERT         ON portal_correos TO facturacion_app;
GRANT SELECT, INSERT, UPDATE ON portal_correos TO facturacion_operador;


-- El disparador. Corre con el rol de quien cambia el estado del comprobante
-- y dentro de su sesión: la fila nueva queda en la empresa correcta.
CREATE OR REPLACE FUNCTION encolar_correo_portal()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.estado IS NOT DISTINCT FROM OLD.estado THEN
        RETURN NEW;
    END IF;

    IF NEW.estado NOT IN ('ACEPTADO', 'ACEPTADO_CON_OBSERVACIONES')
       OR NEW.correo_receptor IS NULL
       OR NEW.tipo_comprobante NOT IN ('01', '03', '07', '08') THEN
        RETURN NEW;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM tenants t
         WHERE t.id = NEW.tenant_id
           AND t.activo
           AND t.identificador IS NOT NULL
           AND t.correo_respuesta IS NOT NULL
    ) THEN
        RETURN NEW;
    END IF;

    INSERT INTO portal_correos (tenant_id, comprobante_id, para)
    VALUES (NEW.tenant_id, NEW.id, NEW.correo_receptor)
    ON CONFLICT (comprobante_id) DO NOTHING;

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS tg_comprobantes_correo_portal ON comprobantes;

CREATE TRIGGER tg_comprobantes_correo_portal
    AFTER UPDATE OF estado ON comprobantes
    FOR EACH ROW
    EXECUTE FUNCTION encolar_correo_portal();

-- Sin tildes: PowerShell 5.1 manda este archivo a psql en ASCII.
COMMENT ON TABLE portal_correos IS
    'Cola del correo de entrega: uno por comprobante aceptado con correo_receptor. PDF adjunto (hasta 1 MB) y enlace de 400 dias al portal.';

COMMIT;