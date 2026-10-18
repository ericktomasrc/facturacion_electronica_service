-- =============================================================================
-- 029 - VIGILANCIA SUNAT, PARTE 1: LA ALARMA DE CODIGOS NUEVOS
--
-- Cada codigo que SUNAT devuelve (a cualquier empresa) queda anotado. Si
-- aparece uno que nunca habia salido, se avisa: por correo y en el panel
-- (Vigilancia SUNAT). El primer cliente que se topa con una regla nueva de
-- SUNAT protege a los demas.
--
--   codigos_sunat           un codigo por fila: respuesta (0, 2xxx, 3xxx...)
--                           u observacion (4xxx). Cuantas veces, cuando, un
--                           ejemplo, y quien lo reviso.
--   codigos_sunat_empresas  que empresas lo recibieron (para contarlas)
--   vigilancia_estado       hasta donde se reviso envio_intentos (una fila)
--   vigilancia_correos      la lista de correos para alertas, ademas de los
--                           administradores del panel
--   vigilancia_alertas      cada aviso, y si su correo ya salio
--
-- LA PRIMERA VUELTA DEL SERVICIO llena codigos_sunat con todo lo que SUNAT
-- ya respondio hasta hoy, marcado como 'historico', SIN avisar. Solo avisan
-- los codigos que salgan despues. Lo hace el servicio y no esta migracion
-- para que la lectura de las observaciones viva en un solo sitio.
--
-- Tablas de la plataforma entera, no de una empresa: sin RLS y solo para el
-- operador (el panel). La aplicacion (clave fac_) no las ve.
--
-- NADA SE BORRA: nadie tiene DELETE. Un correo de la lista se "quita"
-- poniendole fecha, y queda quien lo agrego y quien lo quito.
--
-- Idempotente. Sin tildes a proposito: PowerShell 5.1 la manda a psql en ASCII.
-- =============================================================================

BEGIN;

-- --------------------------------------------------------------- codigos
CREATE TABLE IF NOT EXISTS codigos_sunat (
    codigo             varchar(20) NOT NULL,

    -- 'respuesta':   el codigo del CDR o del error (0 aceptado, 2xxx-3xxx
    --                rechazo, 0100-1999 excepcion del envio)
    -- 'observacion': una nota del CDR de un comprobante aceptado (4xxx)
    clase              text        NOT NULL,

    primera_vez        timestamptz NOT NULL,
    ultima_vez         timestamptz NOT NULL,
    veces              bigint      NOT NULL DEFAULT 1,

    -- Un ejemplo, el de la primera vez: lo que dijo SUNAT y a quien.
    ejemplo_mensaje    text,
    ejemplo_tenant_id  uuid,
    ejemplo_documento  text,

    -- 'historico': ya estaba cuando se instalo la vigilancia (no avisa).
    -- 'nuevo':     aparecio despues (avisa una vez).
    origen             text        NOT NULL,

    -- Quien lo reviso, cuando, y que dijo. El correo se copia: si el usuario
    -- cambia de correo, aqui queda el que tenia ese dia.
    revisado_en        timestamptz,
    revisado_por       uuid,
    revisado_correo    text,
    nota               text,

    CONSTRAINT pk_codigos_sunat PRIMARY KEY (codigo, clase),
    CONSTRAINT ck_codigos_sunat_clase  CHECK (clase IN ('respuesta', 'observacion')),
    CONSTRAINT ck_codigos_sunat_origen CHECK (origen IN ('historico', 'nuevo')),
    CONSTRAINT ck_codigos_sunat_veces  CHECK (veces >= 1),
    CONSTRAINT ck_codigos_sunat_nota   CHECK (nota IS NULL OR length(btrim(nota)) BETWEEN 1 AND 1000),
    CONSTRAINT ck_codigos_sunat_revisado CHECK (
        (revisado_en IS NULL AND revisado_correo IS NULL AND nota IS NULL)
        OR (revisado_en IS NOT NULL AND revisado_correo IS NOT NULL AND nota IS NOT NULL))
);

COMMENT ON TABLE codigos_sunat IS
    'Cada codigo que SUNAT devolvio alguna vez, a cualquier empresa. Los nuevos sin revisar son la alarma de Vigilancia SUNAT.';

CREATE INDEX IF NOT EXISTS ix_codigos_sunat_sin_revisar
    ON codigos_sunat (primera_vez DESC) WHERE origen = 'nuevo' AND revisado_en IS NULL;

CREATE TABLE IF NOT EXISTS codigos_sunat_empresas (
    codigo       varchar(20) NOT NULL,
    clase        text        NOT NULL,
    tenant_id    uuid        NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
    primera_vez  timestamptz NOT NULL,
    CONSTRAINT pk_codigos_sunat_empresas PRIMARY KEY (codigo, clase, tenant_id),
    CONSTRAINT fk_codigos_sunat_empresas_codigo FOREIGN KEY (codigo, clase)
        REFERENCES codigos_sunat (codigo, clase) ON DELETE RESTRICT
);

-- ------------------------------------------------- hasta donde se reviso
CREATE TABLE IF NOT EXISTS vigilancia_estado (
    id                  smallint    PRIMARY KEY DEFAULT 1,
    -- El mayor envio_intentos.id ya revisado. NULL: todavia no se hizo la
    -- primera vuelta (la del historico).
    ultimo_intento_id   bigint,
    inicializado_en     timestamptz,
    ultima_revision_en  timestamptz,
    CONSTRAINT ck_vigilancia_estado_una_fila CHECK (id = 1)
);

INSERT INTO vigilancia_estado (id) VALUES (1) ON CONFLICT (id) DO NOTHING;

-- ------------------------------------------------- correos para alertas
CREATE TABLE IF NOT EXISTS vigilancia_correos (
    id               bigserial   PRIMARY KEY,
    correo           text        NOT NULL,
    agregado_por     uuid,
    agregado_correo  text        NOT NULL,
    agregado_en      timestamptz NOT NULL DEFAULT now(),
    quitado_por      uuid,
    quitado_correo   text,
    quitado_en       timestamptz,
    CONSTRAINT ck_vigilancia_correos_forma CHECK (
        length(correo) BETWEEN 6 AND 254 AND correo ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
    CONSTRAINT ck_vigilancia_correos_quitado CHECK (
        (quitado_en IS NULL AND quitado_correo IS NULL)
        OR (quitado_en IS NOT NULL AND quitado_correo IS NOT NULL))
);

-- Un mismo correo no puede estar dos veces en la lista vigente.
CREATE UNIQUE INDEX IF NOT EXISTS ux_vigilancia_correos_vigente
    ON vigilancia_correos (lower(correo)) WHERE quitado_en IS NULL;

-- ------------------------------------------------------------- alertas
CREATE TABLE IF NOT EXISTS vigilancia_alertas (
    id                 bigserial   PRIMARY KEY,
    -- 'codigo_nuevo' ahora. La prueba de madrugada (parte 2) agregara sus tipos.
    tipo               text        NOT NULL,
    gravedad           text        NOT NULL,
    titulo             text        NOT NULL,
    detalle            text        NOT NULL,
    codigo             varchar(20),
    clase              text,
    creada_en          timestamptz NOT NULL DEFAULT now(),

    -- El correo de la alerta: cuando salio, cuantas veces se intento y por
    -- que fallo la ultima. A quienes se mando queda en enviado_a.
    correo_enviado_en  timestamptz,
    enviado_a          text,
    correo_intentos    smallint    NOT NULL DEFAULT 0,
    correo_error       text,
    proximo_intento_en timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT ck_vigilancia_alertas_gravedad CHECK (gravedad IN ('problema', 'atencion'))
);

CREATE INDEX IF NOT EXISTS ix_vigilancia_alertas_pendientes
    ON vigilancia_alertas (proximo_intento_en) WHERE correo_enviado_en IS NULL;

-- --------------------------------------------------------------- permisos
REVOKE ALL ON codigos_sunat, codigos_sunat_empresas, vigilancia_estado,
              vigilancia_correos, vigilancia_alertas FROM PUBLIC;

GRANT SELECT, INSERT, UPDATE ON codigos_sunat          TO facturacion_operador;
GRANT SELECT, INSERT         ON codigos_sunat_empresas TO facturacion_operador;
GRANT SELECT, UPDATE         ON vigilancia_estado      TO facturacion_operador;
GRANT SELECT, INSERT, UPDATE ON vigilancia_correos     TO facturacion_operador;
GRANT SELECT, INSERT, UPDATE ON vigilancia_alertas     TO facturacion_operador;
GRANT USAGE, SELECT ON SEQUENCE vigilancia_correos_id_seq, vigilancia_alertas_id_seq
    TO facturacion_operador;

DO $$
DECLARE
    t text;
BEGIN
    FOREACH t IN ARRAY ARRAY['codigos_sunat', 'codigos_sunat_empresas', 'vigilancia_estado',
                             'vigilancia_correos', 'vigilancia_alertas'] LOOP
        IF has_table_privilege('facturacion_operador', t, 'DELETE') THEN
            RAISE EXCEPTION '029: el operador no deberia poder borrar en %.', t;
        END IF;
        IF has_table_privilege('facturacion_app', t, 'SELECT') THEN
            RAISE EXCEPTION '029: la aplicacion no deberia ver %.', t;
        END IF;
    END LOOP;

    IF NOT EXISTS (SELECT 1 FROM vigilancia_estado WHERE id = 1) THEN
        RAISE EXCEPTION '029: falta la fila de vigilancia_estado.';
    END IF;

    RAISE NOTICE '029: vigilancia SUNAT (codigos nuevos) lista.';
END $$;

COMMIT;