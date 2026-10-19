-- =============================================================================
-- 036 — PRUEBA Y REAL CON NUMERACIÓN SEPARADA (18 oct 2026)
--
-- Hasta ahora una empresa tenía UNA numeración por serie, y el ambiente
-- (beta o producción) era solo un dato de la empresa. Al pasar a producción
-- los números de beta seguían contando y F001-1 real chocaba con F001-1 de
-- prueba.
--
-- Desde aquí:
--   · Cada serie existe POR AMBIENTE: F001 de beta y F001 de producción son
--     dos filas, cada una con su último número.
--   · `series` pasa a ser una VISTA que enseña solo las del ambiente en que
--     está la empresa AHORA. Todo el código que reserva números, crea o lista
--     series sigue igual y trabaja siempre con las del ambiente actual.
--     La tabla de verdad se llama `series_por_ambiente`.
--   · Cada comprobante guarda el ambiente en que nació (columna `ambiente`,
--     la pone un disparador). El candado de números incluye el ambiente.
--   · Bitácora `ambiente_cambios`: quién cambió una empresa, cuándo, de qué
--     a qué y desde dónde.
--
-- NADA SE BORRA. Los comprobantes de prueba se quedan, marcados 'beta'.
-- Idempotente: se puede correr dos veces.
-- =============================================================================

BEGIN;

-- --- 1. Series por ambiente ---------------------------------------------------

DO $$
BEGIN
    IF to_regclass('public.series_por_ambiente') IS NULL THEN
        ALTER TABLE series RENAME TO series_por_ambiente;
    END IF;
END $$;

ALTER TABLE series_por_ambiente
    ADD COLUMN IF NOT EXISTS ambiente varchar(12);

UPDATE series_por_ambiente s
   SET ambiente = t.ambiente
  FROM tenants t
 WHERE t.id = s.tenant_id
   AND s.ambiente IS NULL;

ALTER TABLE series_por_ambiente ALTER COLUMN ambiente SET NOT NULL;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'ck_series_ambiente') THEN
        ALTER TABLE series_por_ambiente
            ADD CONSTRAINT ck_series_ambiente CHECK (ambiente IN ('beta', 'produccion'));
    END IF;
    -- El candado: una serie por empresa, tipo y AMBIENTE.
    IF EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'ux_series') THEN
        ALTER TABLE series_por_ambiente DROP CONSTRAINT ux_series;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'ux_series_ambiente') THEN
        ALTER TABLE series_por_ambiente
            ADD CONSTRAINT ux_series_ambiente UNIQUE (tenant_id, tipo_comprobante, serie, ambiente);
    END IF;
END $$;

-- El ambiente de una serie nueva es el de la empresa en ese momento.
CREATE OR REPLACE FUNCTION fn_series_ambiente() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.ambiente IS NULL THEN
        SELECT t.ambiente INTO NEW.ambiente FROM tenants t WHERE t.id = NEW.tenant_id;
    END IF;
    RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS tg_series_ambiente ON series_por_ambiente;
CREATE TRIGGER tg_series_ambiente
    BEFORE INSERT ON series_por_ambiente
    FOR EACH ROW EXECUTE FUNCTION fn_series_ambiente();

-- La vista: solo las series del ambiente actual de la empresa. Con
-- security_invoker, la seguridad por empresa (RLS) de la tabla sigue
-- aplicando a quien consulta.
CREATE OR REPLACE VIEW series WITH (security_invoker = true) AS
SELECT s.id, s.tenant_id, s.tipo_comprobante, s.serie, s.ultimo_correlativo,
       s.activo, s.creado_en, s.ambiente
  FROM series_por_ambiente s
 WHERE s.ambiente = (SELECT t.ambiente FROM tenants t WHERE t.id = s.tenant_id);

-- Los mismos permisos que tenía la tabla, ahora también en la vista.
DO $$
DECLARE g record;
BEGIN
    FOR g IN
        SELECT grantee, string_agg(privilege_type, ', ') AS privs
          FROM information_schema.role_table_grants
         WHERE table_schema = 'public' AND table_name = 'series_por_ambiente'
           AND privilege_type IN ('SELECT', 'INSERT', 'UPDATE', 'DELETE')
           AND grantee NOT IN (current_user, 'PUBLIC')
         GROUP BY grantee
    LOOP
        EXECUTE format('GRANT %s ON series TO %I', g.privs, g.grantee);
    END LOOP;
END $$;

-- --- 2. Cada comprobante, con el ambiente en que nació -------------------------

ALTER TABLE comprobantes ADD COLUMN IF NOT EXISTS ambiente varchar(12);

UPDATE comprobantes c
   SET ambiente = t.ambiente
  FROM tenants t
 WHERE t.id = c.tenant_id
   AND c.ambiente IS NULL;

ALTER TABLE comprobantes ALTER COLUMN ambiente SET NOT NULL;

CREATE OR REPLACE FUNCTION fn_comprobantes_ambiente() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.ambiente IS NULL THEN
        SELECT t.ambiente INTO NEW.ambiente FROM tenants t WHERE t.id = NEW.tenant_id;
    END IF;
    RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS tg_comprobantes_ambiente ON comprobantes;
CREATE TRIGGER tg_comprobantes_ambiente
    BEFORE INSERT ON comprobantes
    FOR EACH ROW EXECUTE FUNCTION fn_comprobantes_ambiente();

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'ux_comprobantes_numero') THEN
        ALTER TABLE comprobantes DROP CONSTRAINT ux_comprobantes_numero;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'ux_comprobantes_numero_ambiente') THEN
        ALTER TABLE comprobantes
            ADD CONSTRAINT ux_comprobantes_numero_ambiente
            UNIQUE (tenant_id, tipo_comprobante, serie, correlativo, ambiente);
    END IF;
END $$;

COMMENT ON COLUMN comprobantes.ambiente IS
    'beta o produccion: dónde nació el comprobante. Lo pone tg_comprobantes_ambiente. '
    'Un comprobante de beta nunca se manda a producción, ni al revés.';

-- --- 3. Resúmenes y comunicaciones (RC, RA, RR), también con su ambiente -------
--
-- Un resumen va al SUNAT donde nacieron sus comprobantes. Las boletas de
-- prueba que esperan su resumen cuando la empresa ya pasó a real se informan
-- a beta; las reales, a producción. Nunca mezcladas en un mismo resumen.

ALTER TABLE resumenes ADD COLUMN IF NOT EXISTS ambiente varchar(12);

UPDATE resumenes r
   SET ambiente = t.ambiente
  FROM tenants t
 WHERE t.id = r.tenant_id
   AND r.ambiente IS NULL;

ALTER TABLE resumenes ALTER COLUMN ambiente SET NOT NULL;

CREATE OR REPLACE FUNCTION fn_resumenes_ambiente() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.ambiente IS NULL THEN
        SELECT t.ambiente INTO NEW.ambiente FROM tenants t WHERE t.id = NEW.tenant_id;
    END IF;
    RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS tg_resumenes_ambiente ON resumenes;
CREATE TRIGGER tg_resumenes_ambiente
    BEFORE INSERT ON resumenes
    FOR EACH ROW EXECUTE FUNCTION fn_resumenes_ambiente();

-- --- 4. Bitácora de cambios de ambiente ----------------------------------------

CREATE TABLE IF NOT EXISTS ambiente_cambios (
    id          bigserial   PRIMARY KEY,
    tenant_id   uuid        NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
    de          varchar(12) NOT NULL,
    a           varchar(12) NOT NULL,
    origen      text        NOT NULL,   -- 'plataforma' o 'panel'
    detalle     text,
    creado_en   timestamptz NOT NULL DEFAULT now()
);

CREATE OR REPLACE FUNCTION fn_tenants_ambiente_cambio() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.ambiente IS DISTINCT FROM OLD.ambiente THEN
        INSERT INTO ambiente_cambios (tenant_id, de, a, origen, detalle)
        VALUES (NEW.id, OLD.ambiente, NEW.ambiente,
                coalesce(nullif(current_setting('app.origen_cambio', true), ''), 'panel'),
                nullif(current_setting('app.detalle_cambio', true), ''));
    END IF;
    RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS tg_tenants_ambiente_cambio ON tenants;
CREATE TRIGGER tg_tenants_ambiente_cambio
    AFTER UPDATE OF ambiente ON tenants
    FOR EACH ROW EXECUTE FUNCTION fn_tenants_ambiente_cambio();

DO $$
DECLARE r text;
BEGIN
    FOREACH r IN ARRAY ARRAY['facturacion_operador'] LOOP
        IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
            EXECUTE format('GRANT SELECT, INSERT ON ambiente_cambios TO %I', r);
            EXECUTE format('GRANT USAGE ON SEQUENCE ambiente_cambios_id_seq TO %I', r);
        END IF;
    END LOOP;
END $$;

COMMIT;

DO $$
BEGIN
    RAISE NOTICE '036: series por ambiente (% filas), comprobantes con ambiente (% filas), resúmenes (% filas). Nada se borró.',
        (SELECT count(*) FROM series_por_ambiente), (SELECT count(*) FROM comprobantes),
        (SELECT count(*) FROM resumenes);
END $$;