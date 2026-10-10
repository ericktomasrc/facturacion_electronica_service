-- ===========================================================================
-- 017 — Vínculo entre un comprobante y la comunicación que lo dio de baja
--
-- POR QUÉ NO HAY TABLA NUEVA:
--
-- La comunicación de baja usa el MISMO documento y el MISMO camino que el
-- resumen diario: se arma, se firma, se manda con sendSummary, SUNAT devuelve
-- un ticket y más tarde se consulta el desenlace.
--
-- La tabla `resumenes` ya contemplaba las dos cosas desde la 004:
--
--     -- 'RC' resumen diario de boletas, 'RA' comunicación de baja.
--     tipo  varchar(2)  NOT NULL,
--     CONSTRAINT ck_resumenes_tipo CHECK (tipo IN ('RC', 'RA'))
--
-- Lo único que faltaba era el otro extremo del hilo: saber qué comunicación
-- anuló cada comprobante.
--
--
-- POR QUÉ UNA COLUMNA APARTE Y NO REUTILIZAR `resumen_id`:
--
-- `resumen_id` significa "el resumen que COMUNICA esta boleta". Meter ahí la
-- baja de una factura le daría a la misma columna dos significados opuestos
-- —uno informa la venta, el otro la borra— y bastaría con que una consulta
-- olvidara mirar el `tipo` para que una factura anulada apareciera como
-- comunicada, o al revés.
--
-- Dos columnas no se confunden nunca. Una que significa dos cosas, sí.
--
-- El estado 'ANULADO' ya estaba en ck_comprobantes_estado desde el principio,
-- así que esa restricción no se toca.
-- ===========================================================================

ALTER TABLE comprobantes
    ADD COLUMN IF NOT EXISTS baja_id uuid
        REFERENCES resumenes(id) ON DELETE SET NULL;

ALTER TABLE comprobantes
    ADD COLUMN IF NOT EXISTS baja_motivo text;

CREATE INDEX IF NOT EXISTS ix_comprobantes_baja
    ON comprobantes (baja_id) WHERE baja_id IS NOT NULL;

COMMENT ON COLUMN comprobantes.baja_id IS
    'Comunicación de baja (resumenes.tipo = RA) que anula este comprobante. '
    'NULL mientras no se haya pedido la baja, y vuelve a NULL si SUNAT la '
    'rechaza: el comprobante sigue vivo y se puede volver a intentar.';

COMMENT ON COLUMN comprobantes.baja_motivo IS
    'Por qué se anuló. Lo lee una persona en SUNAT, y dentro de un año lo '
    'leerá quien pregunte por qué desapareció esa factura.';
