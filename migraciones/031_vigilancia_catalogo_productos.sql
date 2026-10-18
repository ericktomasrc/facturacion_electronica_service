-- =============================================================================
-- 031 - VIGILANCIA SUNAT, PARTE 3: EL CATALOGO DE CODIGOS DE PRODUCTO
--
-- Una vez al dia el servicio descarga el Excel oficial del catalogo 25 de
-- SUNAT (CCNU_MOD_2.xlsm) y compara sus codigos con los que usa la
-- plataforma. Si SUNAT agrega o quita codigos, avisa por correo
-- (vigilancia_alertas, tipo 'catalogo_cambio').
--
--   vigilancia_catalogo            el estado: ultimo intento, ultimo exito,
--                                  ultimo error (una sola fila)
--   vigilancia_catalogo_versiones  cada lista distinta que SUNAT publico,
--                                  con lo que cambio respecto a la nuestra
--
-- Tablas de la plataforma entera: sin RLS y solo para el operador (el panel).
-- NADA SE BORRA: nadie tiene DELETE. Idempotente. Sin tildes a proposito:
-- PowerShell 5.1 la manda a psql en ASCII.
-- =============================================================================

BEGIN;

CREATE TABLE IF NOT EXISTS vigilancia_catalogo (
    id                 smallint    PRIMARY KEY DEFAULT 1,
    creado_en          timestamptz NOT NULL DEFAULT now(),
    ultimo_intento_en  timestamptz,
    ultimo_exito_en    timestamptz,
    -- Por que fallo el ultimo intento. NULL si salio bien.
    ultimo_error       text,
    -- Ya se aviso de que no se puede revisar. Vuelve a false al primer exito,
    -- para que una falla larga avise UNA vez y no cada dia.
    falla_avisada      boolean     NOT NULL DEFAULT false,
    CONSTRAINT ck_vigilancia_catalogo_una CHECK (id = 1)
);

CREATE TABLE IF NOT EXISTS vigilancia_catalogo_versiones (
    -- SHA-256 de los codigos ordenados: dos archivos con los mismos codigos
    -- son la misma version aunque el Excel cambie por dentro.
    huella             text        PRIMARY KEY,
    codigos            integer     NOT NULL,
    agregados          integer     NOT NULL,
    quitados           integer     NOT NULL,
    -- Los primeros codigos agregados y quitados, para el correo y el panel.
    agregados_muestra  text,
    quitados_muestra   text,
    sha256_archivo     text        NOT NULL,
    tamano             bigint      NOT NULL,
    -- La fecha que da el servidor de SUNAT (Last-Modified), si la da.
    publicado          text,
    visto_primera      timestamptz NOT NULL DEFAULT now(),
    visto_ultima       timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE vigilancia_catalogo_versiones IS
    'Cada lista de codigos de producto que SUNAT publico (catalogo 25), comparada con la de la plataforma.';

-- --------------------------------------------------------------- permisos
REVOKE ALL ON vigilancia_catalogo, vigilancia_catalogo_versiones FROM PUBLIC;

GRANT SELECT, INSERT, UPDATE ON vigilancia_catalogo, vigilancia_catalogo_versiones
    TO facturacion_operador;

DO $$
DECLARE
    t text;
BEGIN
    FOREACH t IN ARRAY ARRAY['vigilancia_catalogo', 'vigilancia_catalogo_versiones'] LOOP
        IF has_table_privilege('facturacion_operador', t, 'DELETE') THEN
            RAISE EXCEPTION '031: el operador no deberia poder borrar en %.', t;
        END IF;
        IF has_table_privilege('facturacion_app', t, 'SELECT') THEN
            RAISE EXCEPTION '031: la aplicacion no deberia ver %.', t;
        END IF;
    END LOOP;

    IF NOT has_table_privilege('facturacion_operador', 'vigilancia_alertas', 'INSERT') THEN
        RAISE EXCEPTION '031: falta la 029 (el operador tiene que poder crear alertas).';
    END IF;

    RAISE NOTICE '031: vigilancia del catalogo de productos lista.';
END $$;

COMMIT;