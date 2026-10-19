-- =============================================================================
-- 037 — ¿EL CERTIFICADO LO EMITIÓ UNA CERTIFICADORA? (18 oct 2026)
--
-- Un certificado AUTOFIRMADO (el de crear-certificado-prueba.ps1, el de
-- «Usar uno de prueba», el de la madrugada) sirve en SUNAT beta, que no mira
-- quién lo emitió. SUNAT real lo rechaza todo. Desde aquí se guarda quién lo
-- emitió y si es autofirmado, y la revisión para pasar a real lo exige.
--
-- Los certificados ya cargados quedan con autofirmado NULL («no se sabe»):
-- para pasar a real hay que volver a subirlo. En beta todo sigue igual.
-- Nada se borra. Se puede correr dos veces.
-- =============================================================================

BEGIN;

ALTER TABLE certificados ADD COLUMN IF NOT EXISTS emisor text;
ALTER TABLE certificados ADD COLUMN IF NOT EXISTS autofirmado boolean;

COMMENT ON COLUMN certificados.emisor IS
    'Quién emitió el certificado (Issuer). Lo pone AlmacenCertificados al cargarlo.';
COMMENT ON COLUMN certificados.autofirmado IS
    'true: lo firmó él mismo (de prueba, solo beta). false: lo emitió una certificadora. '
    'NULL: cargado antes de la 037, no se sabe; para pasar a real hay que volver a subirlo.';

COMMIT;

DO $$
BEGIN
    RAISE NOTICE '037: certificados con emisor y autofirmado (% cargados antes quedan «no se sabe»). Nada se borró.',
        (SELECT count(*) FROM certificados WHERE autofirmado IS NULL);
END $$;