-- =============================================================================
-- 026 - COPIA AL EMISOR DEL CORREO DE CADA COMPROBANTE (OPCIONAL)
--
-- Decision del 11 de octubre: el emisor puede pedir que le llegue una copia
-- del correo que recibe su cliente con cada comprobante. Va en COPIA OCULTA
-- (el receptor no la ve) al correo de respuesta del emisor.
--
-- DESACTIVADA POR DEFECTO, a proposito: a muchos emisores no les gusta un
-- correo por cada factura que emiten, y ya las ven en su plataforma.
--
-- Sin tildes a proposito: PowerShell 5.1 la manda a psql en ASCII.
-- =============================================================================

BEGIN;

ALTER TABLE tenants
    ADD COLUMN IF NOT EXISTS copia_al_emisor boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN tenants.copia_al_emisor IS
    'Si se manda copia oculta del correo de cada comprobante al correo_respuesta. Opcional; por defecto no.';

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM tenants WHERE copia_al_emisor) THEN
        RAISE NOTICE '026: ya habia empresas con la copia activada (se corrio dos veces).';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
         WHERE table_name = 'tenants' AND column_name = 'copia_al_emisor') THEN
        RAISE EXCEPTION '026: falta la columna copia_al_emisor.';
    END IF;

    RAISE NOTICE '026: copia al emisor lista (desactivada en todas las empresas).';
END $$;

COMMIT;