-- ===========================================================================
-- WEBHOOKS
--
-- EL PROBLEMA: hoy el sistema del cliente tiene que preguntar cada tanto si
-- su comprobante ya fue aceptado. Eso obliga a consultar en bucle, gasta
-- peticiones y añade retraso. Con webhooks le avisamos nosotros.
--
-- EL PATRÓN: bandeja de salida (outbox).
--
-- No se llama al cliente en el momento del cambio de estado. Se escribe una
-- entrega pendiente en una tabla, dentro de la MISMA transacción que cambia
-- el estado, y otro proceso la despacha.
--
-- Por qué así y no llamando directamente: el servidor del cliente puede estar
-- caído o tardar diez segundos en responder. Si el worker esperara a eso, un
-- cliente con problemas frenaría el procesamiento de todos los demás. Y si
-- el envío fallara, el evento se perdería sin rastro.
-- ===========================================================================

CREATE TABLE webhooks (
    id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       uuid        NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,

    nombre          text        NOT NULL DEFAULT '',
    url             text        NOT NULL,

    -- Secreto compartido para firmar cada envío.
    --
    -- Sin firma, cualquiera que conozca la URL del cliente podría enviarle
    -- avisos falsos diciendo que una factura fue aceptada. Con ella, el
    -- cliente comprueba que el mensaje viene de nosotros.
    secreto         text        NOT NULL,

    -- A qué eventos está suscrito. Vacío significa todos.
    eventos         text[]      NOT NULL DEFAULT '{}',

    activo          boolean     NOT NULL DEFAULT true,
    creado_en       timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT ck_webhooks_url CHECK (url ~* '^https?://')
);

CREATE INDEX ix_webhooks_tenant ON webhooks (tenant_id) WHERE activo;


CREATE TABLE webhook_entregas (
    id                  bigserial   PRIMARY KEY,
    webhook_id          uuid        NOT NULL REFERENCES webhooks(id) ON DELETE CASCADE,
    tenant_id           uuid        NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,

    -- Identificador del evento, no de la entrega.
    --
    -- Viaja en el cuerpo para que el cliente pueda descartar duplicados: si
    -- reintentamos porque su respuesta se perdió, recibirá el mismo evento
    -- dos veces y debe poder darse cuenta.
    evento_id           uuid        NOT NULL DEFAULT gen_random_uuid(),

    tipo                varchar(40) NOT NULL,
    comprobante_id      uuid,
    cuerpo              jsonb       NOT NULL,

    estado              varchar(20) NOT NULL DEFAULT 'PENDIENTE',
    intentos            smallint    NOT NULL DEFAULT 0,
    proximo_intento_en  timestamptz,

    ultimo_codigo       integer,
    ultimo_error        text,

    creado_en           timestamptz NOT NULL DEFAULT now(),
    entregado_en        timestamptz,

    CONSTRAINT ck_entregas_estado
        CHECK (estado IN ('PENDIENTE', 'ENTREGADO', 'AGOTADO'))
);

CREATE INDEX ix_entregas_pendientes
    ON webhook_entregas (proximo_intento_en NULLS FIRST, creado_en)
    WHERE estado = 'PENDIENTE';

CREATE INDEX ix_entregas_tenant ON webhook_entregas (tenant_id, creado_en DESC);


-- ===========================================================================
-- DISPARADOR QUE ENCOLA LOS EVENTOS
--
-- POR QUÉ UN DISPARADOR Y NO UNA LLAMADA DESDE EL CÓDIGO:
--
-- Hoy el estado de un comprobante cambia desde tres sitios distintos: el
-- worker de facturas, el de resúmenes y el reproceso manual del panel.
-- Mañana habrá un cuarto.
--
-- Si cada uno tuviera que acordarse de encolar el evento, tarde o temprano
-- uno se olvidaría, y el cliente dejaría de recibir avisos de un tipo de
-- comprobante sin que nadie lo notara. El disparador lo hace imposible: si
-- el estado cambió, el evento existe.
-- ===========================================================================

CREATE OR REPLACE FUNCTION encolar_evento_comprobante() RETURNS trigger AS $$
DECLARE
    tipo_evento text;
    w record;
BEGIN
    -- Solo interesan los desenlaces, no los pasos intermedios. Avisar de
    -- cada transición inundaría al cliente con ruido.
    IF NEW.estado = OLD.estado THEN
        RETURN NEW;
    END IF;

    tipo_evento := CASE NEW.estado
        WHEN 'ACEPTADO' THEN 'comprobante.aceptado'
        WHEN 'ACEPTADO_CON_OBSERVACIONES' THEN 'comprobante.aceptado'
        WHEN 'RECHAZADO' THEN 'comprobante.rechazado'
        WHEN 'ANULADO' THEN 'comprobante.anulado'
        ELSE NULL
    END;

    IF tipo_evento IS NULL THEN
        RETURN NEW;
    END IF;

    FOR w IN
        SELECT id FROM webhooks
         WHERE tenant_id = NEW.tenant_id
           AND activo
           AND (cardinality(eventos) = 0 OR tipo_evento = ANY(eventos))
    LOOP
        INSERT INTO webhook_entregas
            (webhook_id, tenant_id, tipo, comprobante_id, cuerpo)
        VALUES (
            w.id,
            NEW.tenant_id,
            tipo_evento,
            NEW.id,
            jsonb_build_object(
                'tipo', tipo_evento,
                'comprobanteId', NEW.id,
                'numero', NEW.serie || '-' || lpad(NEW.correlativo::text, 8, '0'),
                'tipoComprobante', NEW.tipo_comprobante,
                'serie', NEW.serie,
                'correlativo', NEW.correlativo,
                'fechaEmision', NEW.fecha_emision,
                'moneda', NEW.moneda,
                'importeTotal', NEW.importe_total,
                'estado', NEW.estado,
                'codigoSunat', NEW.codigo_sunat,
                'mensajeSunat', NEW.mensaje_sunat,
                'ocurridoEn', now()
            ));
    END LOOP;

    RETURN NEW;
END
$$ LANGUAGE plpgsql;

CREATE TRIGGER tg_comprobantes_evento
    AFTER UPDATE OF estado ON comprobantes
    FOR EACH ROW EXECUTE FUNCTION encolar_evento_comprobante();


-- ===========================================================================
-- SEGURIDAD Y PERMISOS
-- ===========================================================================

ALTER TABLE webhooks ENABLE ROW LEVEL SECURITY;
ALTER TABLE webhooks FORCE ROW LEVEL SECURITY;

CREATE POLICY aislamiento_tenant ON webhooks
    USING (tenant_id = app_tenant_actual())
    WITH CHECK (tenant_id = app_tenant_actual());

ALTER TABLE webhook_entregas ENABLE ROW LEVEL SECURITY;
ALTER TABLE webhook_entregas FORCE ROW LEVEL SECURITY;

CREATE POLICY aislamiento_tenant ON webhook_entregas
    USING (tenant_id = app_tenant_actual())
    WITH CHECK (tenant_id = app_tenant_actual());

GRANT SELECT, INSERT, UPDATE ON webhooks TO facturacion_app;
GRANT SELECT, INSERT, UPDATE ON webhook_entregas TO facturacion_app;
GRANT USAGE, SELECT ON SEQUENCE webhook_entregas_id_seq TO facturacion_app;

GRANT ALL ON webhooks, webhook_entregas TO facturacion_operador;
GRANT USAGE, SELECT ON SEQUENCE webhook_entregas_id_seq TO facturacion_operador;
