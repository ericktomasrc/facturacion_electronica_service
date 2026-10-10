-- ===========================================================================
-- 018 — Resumen de reversiones
--
-- POR QUÉ HACE FALTA:
--
-- Una factura mal emitida se anula con una comunicación de baja (RA). Un
-- comprobante de retención o de percepción, NO: SUNAT no los admite ahí
-- (error 2308). Esos dos se anulan con un documento distinto, el resumen de
-- reversiones, cuyo identificador empieza por RR.
--
-- Hasta ahora no existía, y el efecto era que una retención emitida por
-- error se quedaba viva para siempre: ni se podía dar de baja, ni el
-- correlativo se podía reutilizar.
--
--
-- NO HAY TABLA NUEVA, y es el mismo razonamiento que en la 017: el RR usa
-- el mismo esquema (VoidedDocuments), el mismo servicio de SUNAT
-- (sendSummary) y el mismo ciclo de ticket que el RC y el RA. Lo único que
-- cambia es qué documentos admite y cómo se llama.
--
-- Lo único que la tabla `resumenes` no contemplaba era el tercer valor de
-- su columna `tipo`. La 004 la dejó así:
--
--     CONSTRAINT ck_resumenes_tipo CHECK (tipo IN ('RC', 'RA'))
--
-- y aquí se le añade el que faltaba.
--
-- El vínculo con los comprobantes ya lo puso la 017: `baja_id` significa
-- "el documento que mata a este comprobante", y da igual que ese documento
-- sea una RA o un RR.
-- ===========================================================================

ALTER TABLE resumenes DROP CONSTRAINT IF EXISTS ck_resumenes_tipo;

ALTER TABLE resumenes ADD CONSTRAINT ck_resumenes_tipo
    CHECK (tipo IN (
        'RC',  -- resumen diario de boletas, y el que las anula con estado 3
        'RA',  -- comunicación de baja: facturas y sus notas
        'RR'   -- resumen de reversiones: retención y percepción
    ));

COMMENT ON COLUMN resumenes.tipo IS
    'RC resumen diario de boletas, RA comunicacion de baja de facturas y '
    'notas, RR resumen de reversiones de retenciones y percepciones. Los '
    'tres viajan por sendSummary y devuelven un ticket.';
