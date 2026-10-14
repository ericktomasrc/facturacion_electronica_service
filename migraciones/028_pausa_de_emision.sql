-- =============================================================================
-- 028 - PAUSA DE EMISION (fase 4c de la plataforma)
--
-- Cuando un contador quita una empresa de su cartera, la plataforma la deja
-- "en pausa". Hasta ahora eso solo cerraba la plataforma: la clave fac_ de la
-- empresa seguia pudiendo emitir desde fuera (otro sistema que la tuviera).
--
-- Con esto, la plataforma le pide al servicio que pause al emisor:
--   * mientras emision_pausada_en tenga fecha, la clave fac_ NO puede emitir
--     ni cambiar nada (todo lo que no sea GET responde 423);
--   * consultar y descargar (GET) siguen funcionando: el titular puede bajar
--     su XML y su CDR;
--   * al recuperar o reanudar la empresa, la plataforma la reactiva.
--
-- Nada se borra. Idempotente. Sin tildes a proposito: PowerShell 5.1 la manda
-- a psql en ASCII.
-- =============================================================================

BEGIN;

ALTER TABLE tenants ADD COLUMN IF NOT EXISTS emision_pausada_en timestamptz;
ALTER TABLE tenants ADD COLUMN IF NOT EXISTS motivo_pausa       text;

COMMENT ON COLUMN tenants.emision_pausada_en IS
    'Con fecha: la clave fac_ solo puede leer (GET). La pone y la quita la plataforma (POST /v1/configuracion/pausa).';

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                    WHERE table_name = 'tenants' AND column_name = 'emision_pausada_en') THEN
        RAISE EXCEPTION '028: no se creo la columna emision_pausada_en.';
    END IF;
    RAISE NOTICE '028: pausa de emision lista.';
END $$;

COMMIT;