-- ===========================================================================
-- 019 — El correo del receptor
--
-- POR QUÉ HACE FALTA:
--
-- El portal del receptor y el correo de entrega viven en este servicio
-- (decisión del 9 de octubre de 2026: un contribuyente que integra por API
-- sin usar la plataforma necesita igual que su cliente reciba el
-- comprobante). Para mandarlo, el servicio tiene que saber a dónde, y hasta
-- ahora `POST /v1/comprobantes` no recibía ningún correo.
--
--
-- VA EN SU PROPIA COLUMNA, NO DENTRO DEL `cpe`, Y ES LO IMPORTANTE:
--
-- El `cpe` es el comprobante tal como se firma y viaja a SUNAT. El correo no
-- es un dato tributario y no pinta nada ahí: meterlo dentro sería arriesgarse
-- a que un generador lo serialice algún día en el XML.
--
--
-- LA COMPROBACIÓN DE LA BASE ES FLOJA A PROPÓSITO. La de forma de verdad está
-- en la API (ReceptorDto.ProblemaCorreo), donde puede devolver un mensaje que
-- se entienda. Aquí solo se ataja lo que nunca puede ser un correo: vacío,
-- con espacios, sin arroba o más largo que el máximo del estándar.
--
-- No necesita GRANT nuevo: facturacion_app tiene INSERT y UPDATE sobre la
-- tabla entera, y eso incluye las columnas que se añadan.
-- ===========================================================================

BEGIN;

ALTER TABLE comprobantes ADD COLUMN IF NOT EXISTS correo_receptor text;

ALTER TABLE comprobantes DROP CONSTRAINT IF EXISTS ck_comprobantes_correo_receptor;

ALTER TABLE comprobantes ADD CONSTRAINT ck_comprobantes_correo_receptor
    CHECK (
        correo_receptor IS NULL OR (
            length(correo_receptor) BETWEEN 3 AND 254
            AND correo_receptor !~ '\s'
            AND position('@' IN correo_receptor) > 1
        )
    );

-- El texto del comentario va sin tildes a proposito: PowerShell 5.1 manda
-- el archivo a psql en ASCII y las convertiria en '?'.
COMMENT ON COLUMN comprobantes.correo_receptor IS
    'A donde se manda el comprobante al ser aceptado (PDF + enlace al portal). '
    'Opcional. No es tributario: nunca va al cpe ni al XML.';

COMMIT;