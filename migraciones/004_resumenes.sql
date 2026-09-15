-- ===========================================================================
-- RESÚMENES DIARIOS
--
-- POR QUÉ LAS BOLETAS NECESITAN TODO ESTO:
--
-- Las facturas se envían de una en una y SUNAT responde al momento. Las
-- boletas no: se emiten al consumidor final, son muchísimas, y SUNAT las
-- recibe agrupadas en un resumen diario.
--
-- Eso cambia el modelo. Un resumen es un documento propio, con su numeración
-- (RC-YYYYMMDD-N), su estado y su ticket. Y cada boleta pasa a depender de
-- él: hasta que SUNAT acepte el resumen, la boleta no está comunicada.
--
-- El efecto práctico es enorme. Si de 100.000 comprobantes diarios 70.000 son
-- boletas, se convierten en un puñado de envíos en vez de 70.000.
-- ===========================================================================

CREATE TABLE resumenes (
    id                  uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id           uuid        NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,

    -- 'RC' resumen diario de boletas, 'RA' comunicación de baja.
    tipo                varchar(2)  NOT NULL,

    -- RC-20260914-1
    identificador       varchar(30) NOT NULL,

    -- Cuándo se emitieron los comprobantes que informa.
    fecha_referencia    date        NOT NULL,

    -- Cuándo se genera este resumen. No confundirlas: SUNAT las valida por
    -- separado y el resumen debe generarse en una fecha posterior o igual.
    fecha_generacion    date        NOT NULL,

    correlativo         integer     NOT NULL,

    estado              varchar(30) NOT NULL DEFAULT 'BORRADOR',

    -- SUNAT responde con un ticket, no con un CDR. El CDR llega después,
    -- al consultar ese ticket.
    ticket              varchar(50),

    codigo_sunat        varchar(10),
    mensaje_sunat       text,

    comprobantes        integer     NOT NULL DEFAULT 0,

    ruta_xml            text,
    ruta_cdr            text,

    intentos_fallidos   smallint    NOT NULL DEFAULT 0,
    proximo_intento_en  timestamptz,

    creado_en           timestamptz NOT NULL DEFAULT now(),
    actualizado_en      timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT ux_resumenes_identificador
        UNIQUE (tenant_id, tipo, identificador),

    CONSTRAINT ck_resumenes_tipo CHECK (tipo IN ('RC', 'RA')),

    CONSTRAINT ck_resumenes_estado CHECK (estado IN (
        'BORRADOR',
        'ENCOLADO',
        'ENVIADO',          -- SUNAT dio ticket, falta consultar el resultado
        'ACEPTADO',
        'ACEPTADO_CON_OBSERVACIONES',
        'RECHAZADO'
    )),

    -- El resumen informa comprobantes de una fecha anterior o del mismo día.
    -- Al revés no tiene sentido y SUNAT lo rechaza.
    CONSTRAINT ck_resumenes_fechas CHECK (fecha_referencia <= fecha_generacion)
);

CREATE INDEX ix_resumenes_tenant ON resumenes (tenant_id, creado_en DESC);

CREATE INDEX ix_resumenes_pendientes
    ON resumenes (estado, proximo_intento_en NULLS FIRST, creado_en)
    WHERE estado IN ('BORRADOR', 'ENCOLADO', 'ENVIADO');


-- ===========================================================================
-- VÍNCULO ENTRE BOLETA Y RESUMEN
--
-- Una boleta sola no dice nada a SUNAT: lo que se comunica es el resumen.
-- Guardar el vínculo permite responder la pregunta que un cliente hará
-- tarde o temprano: "¿esta boleta está declarada, y en qué resumen?"
-- ===========================================================================

ALTER TABLE comprobantes
    ADD COLUMN resumen_id uuid REFERENCES resumenes(id) ON DELETE SET NULL;

CREATE INDEX ix_comprobantes_resumen
    ON comprobantes (resumen_id) WHERE resumen_id IS NOT NULL;

COMMENT ON COLUMN comprobantes.resumen_id IS
    'Resumen en el que se comunicó esta boleta. NULL mientras espera.';


-- ===========================================================================
-- SEGURIDAD Y PERMISOS
-- ===========================================================================

ALTER TABLE resumenes ENABLE ROW LEVEL SECURITY;
ALTER TABLE resumenes FORCE ROW LEVEL SECURITY;

CREATE POLICY aislamiento_tenant ON resumenes
    USING (tenant_id = app_tenant_actual())
    WITH CHECK (tenant_id = app_tenant_actual());

GRANT SELECT, INSERT, UPDATE ON resumenes TO facturacion_app;
GRANT ALL ON resumenes TO facturacion_operador;

CREATE TRIGGER tg_resumenes_actualizado
    BEFORE UPDATE ON resumenes
    FOR EACH ROW EXECUTE FUNCTION marcar_actualizado();
