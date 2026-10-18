-- =============================================================================
-- 035 — RESÚMENES CERRADOS POR «EL TICKET NO EXISTE» (0127) VUELVEN A LA COLA
--
-- Hasta el 17 de octubre, cuando SUNAT contestaba 0127 («El ticket no existe»)
-- al preguntar por un resumen diario, el Worker lo daba por RECHAZADO y con él
-- a sus boletas. Pero el 0127 no es un rechazo: SUNAT perdió el ticket y no
-- dice nada de las boletas. Desde hoy el Worker vuelve a preguntar y, si SUNAT
-- sigue sin conocerlo, reenvía el resumen.
--
-- Esta migración arregla los que ya se cerraron así: el resumen vuelve a
-- ENCOLADO (sin ticket) y sus boletas a ENCOLADO, para que el Worker lo envíe
-- otra vez. Solo los de altas (boletas por resumen_id) y de los últimos 7 días,
-- que es el plazo de SUNAT para informar boletas. Los de anulación no se tocan:
-- sus boletas ya quedaron ACEPTADAS y sueltas; se anulan de nuevo si hace falta.
--
-- Se aplica:
--   Get-Content migraciones\035_resumenes_ticket_perdido.sql -Raw |
--     docker compose exec -T postgres psql -U facturacion_owner -d facturacion -v ON_ERROR_STOP=1
--
-- No se borra nada. Se puede correr dos veces: la segunda no encuentra ninguno.
-- =============================================================================

BEGIN;

DO $$
DECLARE
    t record;
    r record;
    n_res integer := 0;
    n_bol integer := 0;
    k integer;
BEGIN
    -- Empresa por empresa, con su contexto: comprobantes y resumenes tienen RLS.
    FOR t IN SELECT id FROM tenants LOOP
        PERFORM set_config('app.tenant_id', t.id::text, true);

        FOR r IN
            SELECT s.id
              FROM resumenes s
             WHERE s.tenant_id = t.id
               AND s.tipo = 'RC'
               AND s.estado = 'RECHAZADO'
               AND s.codigo_sunat IN ('0127', '127')
               AND s.creado_en > now() - interval '7 days'
               AND EXISTS (SELECT 1 FROM comprobantes c WHERE c.resumen_id = s.id)
        LOOP
            UPDATE resumenes
               SET estado = 'ENCOLADO',
                   ticket = NULL,
                   codigo_sunat = NULL,
                   mensaje_sunat = 'SUNAT perdió el ticket (0127): se reenvía el resumen (migración 035).',
                   intentos_fallidos = 0,
                   proximo_intento_en = NULL
             WHERE id = r.id;

            UPDATE comprobantes
               SET estado = 'ENCOLADO',
                   codigo_sunat = NULL,
                   mensaje_sunat = NULL
             WHERE resumen_id = r.id
               AND estado = 'RECHAZADO';
            GET DIAGNOSTICS k = ROW_COUNT;

            n_res := n_res + 1;
            n_bol := n_bol + k;
        END LOOP;
    END LOOP;

    PERFORM set_config('app.tenant_id', '', true);
    RAISE NOTICE '035: % resumen(es) vuelven a la cola, con % boleta(s).', n_res, n_bol;
END $$;

COMMIT;