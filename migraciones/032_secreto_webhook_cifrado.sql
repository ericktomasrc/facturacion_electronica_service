-- =============================================================================
-- 032 - EL SECRETO DE LOS WEBHOOKS, CIFRADO (punto 2 de seguridad)
--
-- Hasta hoy webhooks.secreto se guardaba en claro: un pg_dump o una copia de
-- la base se llevaba el secreto con el que firmamos los avisos, y con el se
-- pueden falsificar ("SUNAT acepto tu factura").
--
-- Desde esta migracion:
--   - secreto_cifrado (bytea): el secreto cifrado con la llave maestra
--     (AES-GCM, FACTURACION_LLAVE_MAESTRA), igual que certificados y claves SOL.
--   - secreto (text) pasa a ser opcional. Los webhooks nuevos ya no lo llenan.
--   - Al arrancar, la API cifra los que quedaron en claro (llena
--     secreto_cifrado) y NO borra la copia en claro: eso se hace a mano, una
--     vez comprobado que los avisos siguen llegando firmados.
--   - Cada fila tiene al menos uno de los dos.
--
-- Idempotente. NADA SE BORRA aqui. Sin tildes a proposito: PowerShell 5.1 la
-- manda a psql en ASCII.
-- =============================================================================

BEGIN;

ALTER TABLE webhooks ADD COLUMN IF NOT EXISTS secreto_cifrado bytea;

ALTER TABLE webhooks ALTER COLUMN secreto DROP NOT NULL;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'ck_webhooks_algun_secreto') THEN
        ALTER TABLE webhooks ADD CONSTRAINT ck_webhooks_algun_secreto
            CHECK (secreto IS NOT NULL OR secreto_cifrado IS NOT NULL);
    END IF;
END $$;

COMMENT ON COLUMN webhooks.secreto IS
    'OBSOLETO (032): el secreto en claro de los webhooks anteriores. Se vacia a mano una vez cifrado.';
COMMENT ON COLUMN webhooks.secreto_cifrado IS
    'El secreto de firma, cifrado con la llave maestra (AES-GCM: nonce 12 + tag 16 + texto).';

DO $$
BEGIN
    IF NOT has_column_privilege('facturacion_app', 'webhooks', 'secreto_cifrado', 'INSERT') THEN
        RAISE EXCEPTION '032: la aplicacion no puede escribir webhooks.secreto_cifrado.';
    END IF;
    IF NOT has_column_privilege('facturacion_operador', 'webhooks', 'secreto_cifrado', 'UPDATE') THEN
        RAISE EXCEPTION '032: el operador no puede actualizar webhooks.secreto_cifrado.';
    END IF;
    RAISE NOTICE '032: secreto de webhooks cifrado listo.';
END $$;

COMMIT;