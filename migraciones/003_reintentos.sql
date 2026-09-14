-- ===========================================================================
-- CONTROL DE REINTENTOS
--
-- EL PROBLEMA QUE RESUELVE:
--
-- Hasta ahora, un comprobante que fallaba volvía a BORRADOR y el worker lo
-- tomaba en el ciclo siguiente, cinco segundos después. Si SUNAT rechazaba
-- por saturación, le respondíamos pidiendo otra vez de inmediato.
--
-- Eso es contraproducente de dos formas: no le damos tiempo a recuperarse, y
-- ante un servicio que ya está limitando peticiones, insistir es la forma más
-- rápida de que te bloqueen.
--
-- La solución es esperar cada vez más entre intentos: 1 minuto, 5, 15, 1 hora,
-- 6 horas. Si SUNAT vuelve en dos minutos, el comprobante sale casi enseguida.
-- Si está caído medio día, la cola no se convierte en una ametralladora.
-- ===========================================================================

ALTER TABLE comprobantes
    ADD COLUMN intentos_fallidos smallint NOT NULL DEFAULT 0,
    ADD COLUMN proximo_intento_en timestamptz;

COMMENT ON COLUMN comprobantes.intentos_fallidos IS
    'Cuántas veces falló el envío por causas reintentables. Determina cuánto '
    'se espera antes del siguiente intento.';

COMMENT ON COLUMN comprobantes.proximo_intento_en IS
    'Momento a partir del cual el worker puede volver a tomarlo. NULL significa '
    'que puede tomarse de inmediato.';

-- El índice de pendientes ahora tiene que considerar la espera: un
-- comprobante en BORRADOR con próximo intento en el futuro NO debe tomarse.
DROP INDEX IF EXISTS ix_comprobantes_pendientes;

CREATE INDEX ix_comprobantes_pendientes
    ON comprobantes (estado, proximo_intento_en NULLS FIRST, creado_en)
    WHERE estado IN ('BORRADOR', 'ENCOLADO', 'ENVIADO');
