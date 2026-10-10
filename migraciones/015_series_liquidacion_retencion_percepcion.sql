-- ===========================================================================
-- 015 — Series de liquidación de compra, retención y percepción
--
-- POR QUÉ ESTA MIGRACIÓN EXISTE:
--
-- La 014 dejó ck_series_tipo admitiendo '01', '03', '07', '08', '09' y '31',
-- que era todo lo que el sistema emitía entonces. Después aparecieron tres
-- documentos más:
--
--     04   liquidación de compra
--     20   comprobante de retención
--     40   comprobante de percepción
--
-- Sin esto, dar de alta una serie L001, R001 o P001 falla con un error de
-- constraint que no menciona el tipo, y el sistema entero parece roto cuando
-- lo único que pasa es que la tabla no conoce el documento.
--
-- NO SE EDITÓ LA 014 A PROPÓSITO. Una migración ya aplicada no vuelve a
-- ejecutarse: cambiarla habría arreglado las bases nuevas y dejado las
-- existentes como estaban, que es la forma más silenciosa de que dos
-- instalaciones dejen de ser la misma.
-- ===========================================================================

ALTER TABLE series DROP CONSTRAINT IF EXISTS ck_series_tipo;

ALTER TABLE series ADD CONSTRAINT ck_series_tipo
    CHECK (tipo_comprobante IN (
        '01',  -- factura
        '03',  -- boleta de venta
        '04',  -- liquidación de compra
        '07',  -- nota de crédito
        '08',  -- nota de débito
        '09',  -- guía de remisión remitente
        '20',  -- comprobante de retención
        '31',  -- guía de remisión transportista
        '40'   -- comprobante de percepción
    ));


-- ---------------------------------------------------------------------------
-- Las series de los tres documentos nuevos, para cada empresa.
--
-- LAS INICIALES LAS FIJA SUNAT y no son negociables:
--
--     L###   liquidación de compra
--     R###   comprobante de retención
--     P###   comprobante de percepción
--
-- Se crean aquí para que una instalación nueva pueda emitir desde el primer
-- día sin pasar por el panel. ON CONFLICT DO NOTHING las deja intactas si ya
-- existen, así que esta migración se puede volver a correr sin riesgo.
-- ---------------------------------------------------------------------------

INSERT INTO series (tenant_id, tipo_comprobante, serie)
SELECT id, '04', 'L001' FROM tenants
ON CONFLICT DO NOTHING;

INSERT INTO series (tenant_id, tipo_comprobante, serie)
SELECT id, '20', 'R001' FROM tenants
ON CONFLICT DO NOTHING;

INSERT INTO series (tenant_id, tipo_comprobante, serie)
SELECT id, '40', 'P001' FROM tenants
ON CONFLICT DO NOTHING;

INSERT INTO series (tenant_id, tipo_comprobante, serie)
SELECT id, '31', 'V001' FROM tenants
ON CONFLICT DO NOTHING;


-- ---------------------------------------------------------------------------
-- NOTA PARA EL FUTURO: las empresas que se den de alta DESPUÉS de esta
-- migración no reciben estas series. Se las crea el panel al registrarlas, o
-- se repite el bloque de arriba.
--
-- Si algún día el alta de empresas deja de crearlas, el síntoma será siempre
-- el mismo: "la serie no existe o está cerrada" en un cliente nuevo mientras
-- los antiguos funcionan.
-- ---------------------------------------------------------------------------
