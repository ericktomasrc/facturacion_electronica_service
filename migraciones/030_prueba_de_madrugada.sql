-- =============================================================================
-- 030 - VIGILANCIA SUNAT, PARTE 2: LA PRUEBA DE MADRUGADA
--
-- Cada madrugada (3:00, hora de Lima) el servicio emite contra SUNAT beta un
-- comprobante de cada tipo desde una empresa INTERNA, y compara con la noche
-- anterior. Si SUNAT rechaza algo que antes aceptaba, avisa: cambio una regla.
--
--   prueba_madrugada_config   la empresa interna y su clave fac_ (cifrada)
--   pruebas_madrugada         una fila por noche (o por "Correr ahora")
--   pruebas_madrugada_casos   un caso por fila: que se emitio y que paso
--
-- LA EMPRESA INTERNA NUNCA PUEDE PASAR A PRODUCCION: un disparador lo impide.
-- Asi la prueba nunca gasta un correlativo real ni manda nada a SUNAT de
-- verdad.
--
-- El resultado de cada caso NO se copia: se lee del comprobante (o de la
-- baja) cada vez, para que nunca se desfase. Solo se anota el desenlace al
-- compararlo con la noche anterior.
--
-- NADA SE BORRA: nadie tiene DELETE. Idempotente. Sin tildes a proposito:
-- PowerShell 5.1 la manda a psql en ASCII.
-- =============================================================================

BEGIN;

CREATE TABLE IF NOT EXISTS prueba_madrugada_config (
    id               smallint    PRIMARY KEY DEFAULT 1,
    tenant_id        uuid        NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
    -- La clave fac_ de la empresa interna, cifrada con la llave maestra
    -- (como las claves SOL). Sin ella la prueba no puede entrar por la API.
    clave_cifrada    bytea       NOT NULL,
    preparada_en     timestamptz NOT NULL DEFAULT now(),
    preparada_por    text        NOT NULL,
    CONSTRAINT ck_prueba_madrugada_config_una CHECK (id = 1)
);

COMMENT ON TABLE prueba_madrugada_config IS
    'La empresa interna de la prueba de madrugada. Siempre en beta (disparador tg_tenants_interna_solo_beta).';

CREATE TABLE IF NOT EXISTS pruebas_madrugada (
    id             bigserial   PRIMARY KEY,
    -- 'reloj': la de las 3:00. 'panel': el boton "Correr ahora".
    origen         text        NOT NULL,
    iniciada_por   text        NOT NULL,
    fecha_lima     date        NOT NULL,
    iniciada_en    timestamptz NOT NULL DEFAULT now(),
    terminada_en   timestamptz,
    -- Si la corrida entera fallo (por ejemplo, la API no respondia).
    error          text,
    CONSTRAINT ck_pruebas_madrugada_origen CHECK (origen IN ('reloj', 'panel'))
);

-- Una sola corrida del reloj por dia: si la API se reinicia a las 3:05, no
-- vuelve a correr.
CREATE UNIQUE INDEX IF NOT EXISTS ux_pruebas_madrugada_reloj_dia
    ON pruebas_madrugada (fecha_lima) WHERE origen = 'reloj';

CREATE TABLE IF NOT EXISTS pruebas_madrugada_casos (
    id              bigserial   PRIMARY KEY,
    prueba_id       bigint      NOT NULL REFERENCES pruebas_madrugada(id) ON DELETE RESTRICT,
    caso            text        NOT NULL,
    orden           smallint    NOT NULL,

    -- Lo que se emitio. Un comprobante, o una baja (tabla resumenes).
    comprobante_id  uuid,
    resumen_id      uuid,
    numero          text,
    enviado_en      timestamptz,

    -- Si nuestra propia API no lo acepto (400, 500...). Es una alarma igual:
    -- algo de nuestro lado se rompio.
    error_api       text,

    -- Se llena al compararlo con la noche anterior, cuando ya hay desenlace.
    estado_final    text,
    codigo          text,
    mensaje         text,
    comparado_en    timestamptz,
    cambio          text,

    CONSTRAINT ux_pruebas_madrugada_casos UNIQUE (prueba_id, caso),
    CONSTRAINT ck_pruebas_madrugada_casos_estado CHECK (
        estado_final IS NULL OR estado_final IN ('ok', 'obs', 'mal', 'error_api'))
);

CREATE INDEX IF NOT EXISTS ix_pruebas_madrugada_casos_sin_comparar
    ON pruebas_madrugada_casos (prueba_id) WHERE comparado_en IS NULL;

-- ------------------------------------------- la interna nunca a produccion
CREATE OR REPLACE FUNCTION fn_tenants_interna_solo_beta() RETURNS trigger AS $$
BEGIN
    IF NEW.ambiente <> 'beta'
       AND EXISTS (SELECT 1 FROM prueba_madrugada_config WHERE tenant_id = NEW.id) THEN
        RAISE EXCEPTION 'La empresa de la prueba de madrugada es interna y siempre va en beta.'
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS tg_tenants_interna_solo_beta ON tenants;
CREATE TRIGGER tg_tenants_interna_solo_beta
    BEFORE UPDATE OF ambiente ON tenants
    FOR EACH ROW EXECUTE FUNCTION fn_tenants_interna_solo_beta();

-- --------------------------------------------------------------- permisos
REVOKE ALL ON prueba_madrugada_config, pruebas_madrugada, pruebas_madrugada_casos FROM PUBLIC;

GRANT SELECT, INSERT         ON prueba_madrugada_config TO facturacion_operador;
GRANT SELECT, INSERT, UPDATE ON pruebas_madrugada       TO facturacion_operador;
GRANT SELECT, INSERT, UPDATE ON pruebas_madrugada_casos TO facturacion_operador;
GRANT USAGE, SELECT ON SEQUENCE pruebas_madrugada_id_seq, pruebas_madrugada_casos_id_seq
    TO facturacion_operador;

DO $$
DECLARE
    t text;
BEGIN
    FOREACH t IN ARRAY ARRAY['prueba_madrugada_config', 'pruebas_madrugada', 'pruebas_madrugada_casos'] LOOP
        IF has_table_privilege('facturacion_operador', t, 'DELETE') THEN
            RAISE EXCEPTION '030: el operador no deberia poder borrar en %.', t;
        END IF;
        IF has_table_privilege('facturacion_app', t, 'SELECT') THEN
            RAISE EXCEPTION '030: la aplicacion no deberia ver %.', t;
        END IF;
    END LOOP;

    IF has_table_privilege('facturacion_operador', 'prueba_madrugada_config', 'UPDATE') THEN
        RAISE EXCEPTION '030: la empresa interna no se cambia una vez preparada.';
    END IF;

    RAISE NOTICE '030: prueba de madrugada lista.';
END $$;

COMMIT;