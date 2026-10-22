-- =============================================================================
-- 038 — ENLACES DEL PORTAL PARA WHATSAPP (22 oct 2026)
--
-- La plataforma pide un enlace al portal del receptor para mandarlo por
-- WhatsApp (POST /v1/comprobantes/{id}/enlace-portal). Es el mismo acceso
-- que el del correo —solo abre ese comprobante, caduca— con su propio origen
-- para saber de dónde salió.
--
-- Solo cambia la restricción de origen. Nada se borra. Se puede correr dos veces.
-- =============================================================================

BEGIN;

ALTER TABLE portal_accesos DROP CONSTRAINT IF EXISTS ck_portal_accesos_origen;
ALTER TABLE portal_accesos ADD CONSTRAINT ck_portal_accesos_origen
    CHECK (origen IN ('consulta', 'correo', 'whatsapp'));

COMMENT ON COLUMN portal_accesos.origen IS
    'consulta: el receptor lo buscó con sus datos. correo: el enlace del correo de entrega. '
    'whatsapp (038): el enlace que la plataforma manda por WhatsApp.';

COMMIT;

DO $$ BEGIN RAISE NOTICE '038: enlaces del portal con origen whatsapp. Nada se borró.'; END $$;