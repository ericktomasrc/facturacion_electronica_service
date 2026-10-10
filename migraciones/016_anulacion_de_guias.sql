-- ===========================================================================
-- 016 — Registro de la anulación de una guía
--
-- POR QUÉ HACE FALTA:
--
-- Una guía de remisión NO SE PUEDE ANULAR DESDE AQUÍ. SUNAT no publica
-- ningún servicio para eso: la anula una persona entrando con Clave SOL.
--
-- El problema es lo que pasa después. La guía queda muerta en SUNAT y VIVA
-- en esta base: el panel la sigue mostrando activa y una factura posterior
-- puede referenciarla como si existiera.
--
-- Estas tres columnas guardan que alguien la anuló, cuándo y por qué. No
-- anulan nada: registran un hecho que ocurrió fuera.
--
-- El estado 'ANULADO' ya estaba contemplado en ck_guias_estado desde el
-- principio, así que no hay que tocar esa restricción.
-- ===========================================================================

ALTER TABLE guias ADD COLUMN IF NOT EXISTS anulada_en    date;
ALTER TABLE guias ADD COLUMN IF NOT EXISTS anulada_motivo text;
ALTER TABLE guias ADD COLUMN IF NOT EXISTS anulada_por   text;

COMMENT ON COLUMN guias.anulada_en IS
    'Cuándo se anuló en SUNAT, no cuándo se registró aquí.';

COMMENT ON COLUMN guias.anulada_motivo IS
    'Por qué. No lo exige SUNAT: lo exige quien pregunte dentro de un año.';

COMMENT ON COLUMN guias.anulada_por IS
    'Quién dice que la anuló. Es el rastro de quién afirma qué.';
