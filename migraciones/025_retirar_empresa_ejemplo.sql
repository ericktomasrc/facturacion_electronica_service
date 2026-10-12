-- =============================================================================
-- 025 - SE RETIRA LA EMPRESA DE EJEMPLO DE LA 001
--
-- La 001 mete una empresa de ejemplo (RUC 20601234567, MI EMPRESA SAC) y la 002
-- le crea una clave de acceso cuyo texto quedo en los archivos de entonces.
-- Desde el alta por la plataforma (parte C), toda empresa nace en la
-- plataforma: una empresa que no esta alli no deberia estar activa aqui.
--
-- NADA SE BORRA: la empresa, sus series y su clave quedan DESACTIVADAS (la
-- clave, ademas, revocada). La 001 y la 002 no se tocan: son el registro de
-- como empezo la base.
--
-- Solo si sigue siendo la de ejemplo: ese RUC, esa razon social y ningun
-- comprobante ni guia. Si alguien la uso de verdad, no se toca y se avisa.
--
-- Se puede correr dos veces: la segunda no cambia nada.
-- Sin tildes a proposito: PowerShell 5.1 la manda a psql en ASCII.
-- =============================================================================

BEGIN;

DO $$
DECLARE
    v_id     uuid;
    v_usada  boolean;
    v_claves integer;
    v_series integer;
BEGIN
    SELECT id INTO v_id
      FROM tenants
     WHERE ruc = '20601234567'
       AND razon_social = 'MI EMPRESA SAC';

    IF v_id IS NULL THEN
        RAISE NOTICE '025: no hay empresa de ejemplo. Nada que hacer.';
        RETURN;
    END IF;

    SELECT EXISTS (SELECT 1 FROM comprobantes WHERE tenant_id = v_id)
        OR EXISTS (SELECT 1 FROM guias WHERE tenant_id = v_id)
      INTO v_usada;

    IF v_usada THEN
        RAISE NOTICE '025: la empresa 20601234567 tiene comprobantes o guias: NO se toca. Revisala en el panel.';
        RETURN;
    END IF;

    UPDATE api_keys
       SET activo = false,
           revocado_en = COALESCE(revocado_en, now())
     WHERE tenant_id = v_id
       AND (activo OR revocado_en IS NULL);
    GET DIAGNOSTICS v_claves = ROW_COUNT;

    UPDATE series
       SET activo = false
     WHERE tenant_id = v_id
       AND activo;
    GET DIAGNOSTICS v_series = ROW_COUNT;

    UPDATE tenants
       SET activo = false
     WHERE id = v_id
       AND activo;

    RAISE NOTICE '025: empresa de ejemplo 20601234567 desactivada (% claves revocadas, % series desactivadas). Nada se borro.',
                 v_claves, v_series;
END $$;

-- La comprobacion: si sigue ahi sin uso, no puede quedar nada activo.
DO $$
BEGIN
    IF EXISTS (
        SELECT 1
          FROM tenants t
         WHERE t.ruc = '20601234567'
           AND t.razon_social = 'MI EMPRESA SAC'
           AND NOT EXISTS (SELECT 1 FROM comprobantes c WHERE c.tenant_id = t.id)
           AND NOT EXISTS (SELECT 1 FROM guias g WHERE g.tenant_id = t.id)
           AND (t.activo
                OR EXISTS (SELECT 1 FROM api_keys k WHERE k.tenant_id = t.id AND (k.activo OR k.revocado_en IS NULL))
                OR EXISTS (SELECT 1 FROM series s WHERE s.tenant_id = t.id AND s.activo))) THEN
        RAISE EXCEPTION '025: la empresa de ejemplo sigue con algo activo.';
    END IF;
END $$;

COMMIT;