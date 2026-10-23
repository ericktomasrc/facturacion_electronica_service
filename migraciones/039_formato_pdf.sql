-- =============================================================================
-- 039 — EL FORMATO DEL PDF DE CADA EMPRESA (23 oct 2026)
--
-- Dos formatos A4 para la representación impresa de facturas, boletas y
-- notas:
--   · moderno  el de siempre (por defecto);
--   · clasico  el estilo del PDF del portal de SUNAT: blanco y negro, recuadro
--              del RUC, cuadro de totales completo y cuadro de detracción,
--              con nuestro QR y valor resumen en el pie.
--
-- Lo elige cada empresa (Configuración › Correo y marca). Vale para el PDF del
-- panel, el del portal del receptor y el que va adjunto en el correo. El
-- ticket no cambia. Nada se borra. Se puede correr dos veces.
-- =============================================================================

BEGIN;

ALTER TABLE tenants ADD COLUMN IF NOT EXISTS formato_pdf text NOT NULL DEFAULT 'moderno';

ALTER TABLE tenants DROP CONSTRAINT IF EXISTS ck_tenants_formato_pdf;
ALTER TABLE tenants ADD CONSTRAINT ck_tenants_formato_pdf CHECK (formato_pdf IN ('moderno', 'clasico'));

COMMENT ON COLUMN tenants.formato_pdf IS
    '039: formato A4 del PDF de la empresa. moderno (por defecto) o clasico (estilo del portal de SUNAT).';

COMMIT;

DO $$ BEGIN RAISE NOTICE '039: formato del PDF por empresa (moderno / clásico). Nada se borró.'; END $$;