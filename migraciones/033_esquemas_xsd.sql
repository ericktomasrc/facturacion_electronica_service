-- =============================================================================
-- 033 - VIGILANCIA SUNAT, PARTE 4: LOS ESQUEMAS XSD
--
-- Antes de enviar cada XML, el servicio lo compara con el molde oficial (XSD)
-- de su tipo. Faltaban los de resumen diario, baja, retencion y percepcion.
-- Ahora se suben desde el panel (SUNAT no deja bajarlos a un programa):
--
--   xsd_esquemas   los archivos subidos (maindoc/... y common/...). El Worker
--                  los copia a su carpeta y los usa sin reiniciar.
--   xsd_estado     lo que el Worker tiene de verdad cargado (una fila): es lo
--                  que ensena la pestana, no lo que se supone.
--   xsd_avisos     cada XML que no cumplio su molde: cuando, empresa,
--                  documento, linea, posicion y que falla.
--
-- Tablas de la plataforma entera: sin RLS y solo para el operador (el panel y
-- el Worker). NADA SE BORRA: nadie tiene DELETE. Idempotente. Sin tildes a
-- proposito: PowerShell 5.1 la manda a psql en ASCII.
-- =============================================================================

BEGIN;

CREATE TABLE IF NOT EXISTS xsd_esquemas (
    -- 'maindoc/UBL-Invoice-2.1.xsd' o 'common/UBL-CommonBasicComponents-2.1.xsd'
    ruta        text        PRIMARY KEY
                            CHECK (ruta ~ '^(maindoc|common)/[A-Za-z0-9._-]+\.xsd$'),
    contenido   bytea       NOT NULL,
    sha256      text        NOT NULL,
    tamano      integer     NOT NULL,
    subido_en   timestamptz NOT NULL DEFAULT now(),
    subido_por  text        NOT NULL
);

COMMENT ON TABLE xsd_esquemas IS
    'Los esquemas XSD subidos desde el panel. Subir uno con la misma ruta lo reemplaza.';

CREATE TABLE IF NOT EXISTS xsd_estado (
    id           smallint    PRIMARY KEY DEFAULT 1,
    maquina      text        NOT NULL,
    informado_en timestamptz NOT NULL DEFAULT now(),
    -- [{"raiz":"Invoice","archivo":"UBL-Invoice-2.1.xsd","cargado":true}, ...]
    moldes       jsonb       NOT NULL,
    bloquea      boolean     NOT NULL,
    -- La huella de xsd_esquemas que el Worker ya copio a su carpeta.
    huella       text,
    CONSTRAINT ck_xsd_estado_una CHECK (id = 1)
);

CREATE TABLE IF NOT EXISTS xsd_avisos (
    id          bigserial   PRIMARY KEY,
    creado_en   timestamptz NOT NULL DEFAULT now(),
    tenant_id   uuid,
    ruc         text,
    -- F001-00000031, RC-20261014-1, RA-20261014-2...
    documento   text        NOT NULL,
    raiz        text,
    esquema     text,
    linea       integer     NOT NULL DEFAULT 0,
    posicion    integer     NOT NULL DEFAULT 0,
    -- En castellano (ExplicadorXsd) y tal como lo dio .NET.
    mensaje     text        NOT NULL,
    original    text        NOT NULL
);

CREATE INDEX IF NOT EXISTS ix_xsd_avisos_creado ON xsd_avisos (creado_en DESC);

COMMENT ON TABLE xsd_avisos IS
    'Cada error de un XML contra su esquema XSD, antes de enviarlo a SUNAT.';

-- --------------------------------------------------------------- permisos
REVOKE ALL ON xsd_esquemas, xsd_estado, xsd_avisos FROM PUBLIC;

GRANT SELECT, INSERT, UPDATE ON xsd_esquemas, xsd_estado, xsd_avisos TO facturacion_operador;
GRANT USAGE, SELECT ON SEQUENCE xsd_avisos_id_seq TO facturacion_operador;

DO $$
DECLARE
    t text;
BEGIN
    FOREACH t IN ARRAY ARRAY['xsd_esquemas', 'xsd_estado', 'xsd_avisos'] LOOP
        IF has_table_privilege('facturacion_operador', t, 'DELETE') THEN
            RAISE EXCEPTION '033: el operador no deberia poder borrar en %.', t;
        END IF;
        IF has_table_privilege('facturacion_app', t, 'SELECT') THEN
            RAISE EXCEPTION '033: la aplicacion no deberia ver %.', t;
        END IF;
        IF NOT has_table_privilege('facturacion_operador', t, 'INSERT') THEN
            RAISE EXCEPTION '033: el operador tiene que poder escribir en %.', t;
        END IF;
    END LOOP;

    RAISE NOTICE '033: esquemas XSD listos.';
END $$;

COMMIT;