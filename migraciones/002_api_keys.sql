-- ===========================================================================
-- CLAVES DE ACCESO A LA API
--
-- Cada empresa consume el servicio con su propia clave. Esa clave es lo que
-- resuelve el tenant_id de cada petición, y por lo tanto lo que hace que el
-- aislamiento de Row Level Security signifique algo en la práctica.
--
-- LAS CLAVES SE GUARDAN COMO HASH, NUNCA EN CLARO.
--
-- Es el mismo criterio que con las contraseñas: si alguien accede a la base,
-- no debe poder suplantar a ningún cliente. La contrapartida es que una clave
-- perdida no se recupera, solo se revoca y se emite otra. Eso es correcto.
--
-- El prefijo sí se guarda legible, para que en el panel se pueda distinguir
-- una clave de otra sin exponerla entera.
-- ===========================================================================

CREATE TABLE api_keys (
    id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id   uuid        NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,

    -- Para identificarla en el panel: "ERP producción", "pruebas", etc.
    nombre      text        NOT NULL DEFAULT '',

    -- Primeros caracteres de la clave. Solo para mostrar.
    prefijo     varchar(20) NOT NULL,

    -- SHA-256 de la clave completa, en hexadecimal.
    hash        varchar(64) NOT NULL UNIQUE,

    activo      boolean     NOT NULL DEFAULT true,
    ultimo_uso  timestamptz,
    creado_en   timestamptz NOT NULL DEFAULT now(),
    revocado_en timestamptz
);

CREATE INDEX ix_api_keys_hash ON api_keys (hash) WHERE activo;
CREATE INDEX ix_api_keys_tenant ON api_keys (tenant_id);

-- Esta tabla NO lleva Row Level Security, y es deliberado:
-- se consulta ANTES de saber de qué tenant se trata. Es justamente la
-- consulta que resuelve el tenant. Por eso el rol de la aplicación solo
-- puede leerla, nunca escribirla: crear y revocar claves es tarea del
-- panel de administración, que usa el rol de operador.

GRANT SELECT ON api_keys TO facturacion_app;
GRANT UPDATE (ultimo_uso) ON api_keys TO facturacion_app;
GRANT ALL ON api_keys TO facturacion_operador;


-- ===========================================================================
-- CLAVE DE DESARROLLO
--
-- Solo para el ambiente local. En producción las claves se generan desde el
-- panel y se muestran UNA sola vez, al crearlas.
--
-- Clave en claro:  fac_dev_UkV5QkFOX0RFU0FSUk9MTE9fMjAyNg
--
-- Está escrita aquí a propósito, para que quede claro que es de desarrollo
-- y que no debe replicarse en producción.
-- ===========================================================================

INSERT INTO api_keys (tenant_id, nombre, prefijo, hash)
SELECT id,
       'Desarrollo local',
       'fac_dev_UkV5QkFO',
       '56afcfae8fdea5a8e83b04f228ca97cb9a7ddd16fb9d6fb364258a06aedcbf0c'
  FROM tenants
 WHERE ruc = '20601234567';
