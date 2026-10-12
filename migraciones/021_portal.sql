-- ===========================================================================
-- 021 — El portal del receptor: accesos e intentos
--
-- POR QUÉ HACE FALTA:
--
-- El cliente de cada emisor entra en comprobantes.reyban.pe/{empresa}, da
-- cinco datos de su comprobante y lo descarga (opción A). Más adelante
-- llegará también por un enlace del correo (opción B). Las dos cosas acaban
-- en un ACCESO: una fila que dice "quien tenga este identificador puede ver
-- este comprobante hasta tal hora".
--
--
-- LAS DOS TABLAS NUEVAS NO TIENEN RLS, Y ES A PROPÓSITO. Siguen el mismo
-- patrón que api_keys:
--
--   - Se buscan por un hash que nadie puede adivinar, no por empresa. La
--     empresa sale de la fila, igual que con una clave `fac_`.
--   - No guardan nada del comprobante: solo ids, hashes, IP y horas. El
--     comprobante en sí se sigue leyendo SIEMPRE con la sesión de la
--     empresa, con RLS, y además se comprueba que el acceso es de la empresa
--     de la dirección.
--   - El límite por IP tiene que contar intentos de TODAS las empresas: con
--     RLS haría falta una función SECURITY DEFINER, que en producción solo
--     funciona si el dueño de la tabla se salta RLS. Sin RLS no hace falta.
--
--
-- NO SE GUARDA EL IDENTIFICADOR DEL ACCESO, SOLO SU SHA-256. Quien se lleve
-- una copia de la base no se lleva enlaces que funcionen.
--
-- NO SE GUARDA EL DOCUMENTO DEL RECEPTOR EN LOS INTENTOS, SOLO SU SHA-256
-- (junto con la empresa). Para contar fallos basta con saber si dos intentos
-- son del mismo documento, no cuál es.
--
-- NADA SE BORRA: no hay DELETE para nadie. Un acceso se anula (anulado_en).
-- ===========================================================================

BEGIN;

-- Buscar por número dentro de una empresa. El índice único que ya existe
-- lleva el tipo de comprobante en medio, y el portal no lo pregunta.
CREATE INDEX IF NOT EXISTS ix_comprobantes_portal
    ON comprobantes (tenant_id, serie, correlativo);


CREATE TABLE IF NOT EXISTS portal_accesos (
    id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       uuid        NOT NULL REFERENCES tenants(id)      ON DELETE RESTRICT,
    comprobante_id  uuid        NOT NULL REFERENCES comprobantes(id) ON DELETE RESTRICT,
    hash            char(64)    NOT NULL,
    origen          text        NOT NULL,
    creado_en       timestamptz NOT NULL DEFAULT now(),
    expira_en       timestamptz NOT NULL,
    anulado_en      timestamptz,
    anulado_motivo  text,
    usos            integer     NOT NULL DEFAULT 0,
    ultimo_uso_en   timestamptz,

    CONSTRAINT ux_portal_accesos_hash    UNIQUE (hash),
    CONSTRAINT ck_portal_accesos_hash    CHECK (hash ~ '^[0-9a-f]{64}$'),
    CONSTRAINT ck_portal_accesos_origen  CHECK (origen IN ('consulta', 'correo')),
    CONSTRAINT ck_portal_accesos_expira  CHECK (expira_en > creado_en),
    CONSTRAINT ck_portal_accesos_anulado CHECK ((anulado_en IS NULL) = (anulado_motivo IS NULL))
);

CREATE INDEX IF NOT EXISTS ix_portal_accesos_comprobante
    ON portal_accesos (comprobante_id);


CREATE TABLE IF NOT EXISTS portal_intentos (
    id           uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id    uuid        NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
    documento    char(64)    NOT NULL,
    ip           text        NOT NULL,
    exito        boolean     NOT NULL,
    ocurrido_en  timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT ck_portal_intentos_documento CHECK (documento ~ '^[0-9a-f]{64}$')
);

-- Solo se cuentan los fallos, así que solo se indexan los fallos.
CREATE INDEX IF NOT EXISTS ix_portal_intentos_documento
    ON portal_intentos (tenant_id, documento, ocurrido_en) WHERE NOT exito;

CREATE INDEX IF NOT EXISTS ix_portal_intentos_ip
    ON portal_intentos (ip, ocurrido_en) WHERE NOT exito;


-- PERMISOS. La aplicación crea accesos, cuenta sus usos y registra intentos.
-- Anular un acceso lo hace el operador desde el panel (paso 4). Nadie borra.
GRANT SELECT, INSERT                 ON portal_accesos  TO facturacion_app;
GRANT UPDATE (usos, ultimo_uso_en)   ON portal_accesos  TO facturacion_app;
GRANT SELECT, INSERT                 ON portal_intentos TO facturacion_app;

GRANT SELECT, INSERT, UPDATE         ON portal_accesos  TO facturacion_operador;
GRANT SELECT                         ON portal_intentos TO facturacion_operador;


-- Los comentarios van sin tildes: PowerShell 5.1 manda este archivo a psql
-- en ASCII.
COMMENT ON TABLE portal_accesos IS
    'Quien tenga el identificador (aqui solo su SHA-256) puede ver ese comprobante hasta expira_en. Consulta: 30 min. Correo: 400 dias. Se anula, no se borra.';
COMMENT ON TABLE portal_intentos IS
    'Busquedas del portal, para limitar intentos: 5 fallos en 15 min por documento y 30 en 1 hora por IP. documento es un SHA-256.';

COMMIT;