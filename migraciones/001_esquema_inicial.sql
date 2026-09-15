-- ===========================================================================
-- ESQUEMA INICIAL DEL SERVICIO DE FACTURACIÓN
--
-- Las cuatro decisiones irreversibles del documento están aquí dentro:
--
--   1. tenant_id en todas las tablas, con Row Level Security activo.
--   2. Correlativos con candado en la base, no solo en el código.
--   3. Certificados guardados cifrados, nunca en claro.
--   4. Bitácora append-only: nunca UPDATE, nunca DELETE.
--
-- Retrofitear cualquiera de estas cuatro con clientes en producción es
-- reescribir medio sistema. Por eso van desde la primera migración.
-- ===========================================================================

-- gen_random_uuid() viene de aquí.
CREATE EXTENSION IF NOT EXISTS pgcrypto;


-- ===========================================================================
-- ROLES
--
-- Tres roles con propósitos distintos. La separación no es burocracia:
-- es lo que hace que Row Level Security signifique algo. Si la aplicación
-- se conectara como dueña de las tablas, podría saltarse las políticas.
-- ===========================================================================

DO $$
BEGIN
    -- La aplicación. Sujeto a RLS: solo ve las filas de su tenant.
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'facturacion_app') THEN
        CREATE ROLE facturacion_app LOGIN PASSWORD 'cambiame_en_produccion';
    END IF;

    -- El operador de la plataforma. Ve todo, para soporte y bitácora.
    -- BYPASSRLS es un privilegio fuerte: úsalo solo desde el panel interno.
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'facturacion_operador') THEN
        CREATE ROLE facturacion_operador LOGIN PASSWORD 'cambiame_en_produccion' BYPASSRLS;
    END IF;
END
$$;


-- ===========================================================================
-- TENANTS
--
-- Un tenant es una empresa emisora. Un RUC, un tenant.
-- ===========================================================================

CREATE TABLE tenants (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),

    ruc                 varchar(11) NOT NULL UNIQUE,
    razon_social        text        NOT NULL,
    nombre_comercial    text,

    ubigeo              varchar(6)  NOT NULL DEFAULT '150101',
    direccion           text        NOT NULL DEFAULT '',
    distrito            text        NOT NULL DEFAULT '',
    provincia           text        NOT NULL DEFAULT '',
    departamento        text        NOT NULL DEFAULT '',

    -- 'beta' o 'produccion'. Determina a qué endpoints se envía.
    ambiente            varchar(20) NOT NULL DEFAULT 'beta',

    -- Credenciales SOL. La clave va cifrada, igual que el certificado.
    -- Debe ser el usuario SECUNDARIO del contribuyente, nunca el principal.
    usuario_sol         text,
    clave_sol_cifrada   bytea,

    -- Tope de envíos simultáneos de este tenant. Es el semáforo del que
    -- habla el documento: impide que una empresa que descarga 40.000 boletas
    -- se coma todos los workers y deje esperando a las demás.
    max_concurrencia    smallint    NOT NULL DEFAULT 3,

    activo              boolean     NOT NULL DEFAULT true,
    creado_en           timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT ck_tenants_ambiente
        CHECK (ambiente IN ('beta', 'produccion')),
    CONSTRAINT ck_tenants_ruc
        CHECK (ruc ~ '^[0-9]{11}$')
);

COMMENT ON COLUMN tenants.max_concurrencia IS
    'Máximo de envíos simultáneos. Evita que un tenant ocupe todos los workers.';


-- ===========================================================================
-- CERTIFICADOS
--
-- Es la llave con la que se firma en nombre de otro. Se guarda cifrado,
-- nunca en claro. El cifrado lo hace la aplicación antes de insertar:
-- aquí solo viven bytes opacos.
-- ===========================================================================

CREATE TABLE certificados (
    id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       uuid        NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,

    pfx_cifrado     bytea       NOT NULL,
    clave_cifrada   bytea       NOT NULL,

    -- Datos legibles para el panel, extraídos al cargar el certificado.
    subject         text        NOT NULL DEFAULT '',
    huella          varchar(64) NOT NULL DEFAULT '',
    valido_desde    timestamptz,
    valido_hasta    timestamptz NOT NULL,

    activo          boolean     NOT NULL DEFAULT true,
    creado_en       timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX ix_certificados_tenant ON certificados (tenant_id) WHERE activo;

-- Un solo certificado activo por tenant: dos activos significan que nadie
-- sabe con cuál se está firmando.
CREATE UNIQUE INDEX ux_certificados_activo_por_tenant
    ON certificados (tenant_id) WHERE activo;

COMMENT ON COLUMN certificados.valido_hasta IS
    'Vencimiento. Hay que alertar con semanas de anticipación: un certificado '
    'vencido detiene la facturación del cliente y el aviso nunca llega solo.';


-- ===========================================================================
-- SERIES
--
-- Aquí vive el correlativo. Cada tenant lleva el suyo por tipo y serie.
-- ===========================================================================

CREATE TABLE series (
    id                  uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id           uuid        NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,

    tipo_comprobante    varchar(2)  NOT NULL,
    serie               varchar(4)  NOT NULL,
    ultimo_correlativo  integer     NOT NULL DEFAULT 0,

    activo              boolean     NOT NULL DEFAULT true,
    creado_en           timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT ux_series UNIQUE (tenant_id, tipo_comprobante, serie),
    CONSTRAINT ck_series_correlativo CHECK (ultimo_correlativo >= 0)
);

COMMENT ON TABLE series IS
    'El correlativo se reserva con SELECT ... FOR UPDATE dentro de la misma '
    'transacción que inserta el comprobante. Nunca con MAX(correlativo) + 1: '
    'dos peticiones simultáneas obtendrían el mismo número.';


-- ===========================================================================
-- COMPROBANTES
--
-- Una sola tabla física para todas las empresas, muchos historiales lógicos.
-- El aislamiento lo garantiza Row Level Security, más abajo.
-- ===========================================================================

CREATE TABLE comprobantes (
    id                  uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id           uuid        NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,

    tipo_comprobante    varchar(2)  NOT NULL,
    serie               varchar(4)  NOT NULL,
    correlativo         integer     NOT NULL,

    fecha_emision       date        NOT NULL,
    moneda              varchar(3)  NOT NULL DEFAULT 'PEN',
    importe_total       numeric(14,2) NOT NULL DEFAULT 0,

    -- Estado actual. La historia completa vive en envio_intentos.
    estado              varchar(30) NOT NULL DEFAULT 'BORRADOR',

    codigo_sunat        varchar(10),
    mensaje_sunat       text,

    -- Para los documentos de envío asíncrono (resúmenes, bajas).
    ticket              varchar(50),

    -- LA SEPARACIÓN EN DOS CAPAS DEL DOCUMENTO:
    --   cpe   = lo que exige SUNAT. Es lo único que va al XML.
    --   extra = los campos propios de cada empresa. NUNCA tocan el XML.
    cpe                 jsonb       NOT NULL,
    extra               jsonb       NOT NULL DEFAULT '{}'::jsonb,

    -- Los archivos van a S3 o MinIO; aquí solo la ruta.
    -- Guardar blobs en la base hace imposible el backup a los seis meses.
    ruta_xml            text,
    ruta_cdr            text,
    ruta_pdf            text,

    -- Resumen del XML firmado, para detectar alteraciones.
    hash_cpe            varchar(64),

    -- Evita duplicados por doble clic o por un reintento del cliente.
    idempotency_key     text,

    creado_en           timestamptz NOT NULL DEFAULT now(),
    actualizado_en      timestamptz NOT NULL DEFAULT now(),

    -- EL CANDADO DE LOS CORRELATIVOS. Un duplicado no es un bug: es un
    -- problema tributario. Esta restricción lo hace imposible aunque el
    -- código tenga un error de concurrencia.
    CONSTRAINT ux_comprobantes_numero
        UNIQUE (tenant_id, tipo_comprobante, serie, correlativo),

    CONSTRAINT ck_comprobantes_estado CHECK (estado IN (
        'BORRADOR',
        'FIRMADO',
        'ENCOLADO',
        'ENVIADO',
        'ACEPTADO',
        'ACEPTADO_CON_OBSERVACIONES',
        'RECHAZADO',
        'ANULADO'
    )),

    CONSTRAINT ck_comprobantes_correlativo CHECK (correlativo > 0)
);

-- Idempotencia: la misma clave no puede producir dos comprobantes.
-- Es un índice parcial porque la mayoría de las filas no la llevan.
CREATE UNIQUE INDEX ux_comprobantes_idempotencia
    ON comprobantes (tenant_id, idempotency_key)
    WHERE idempotency_key IS NOT NULL;

-- Consulta típica del panel: los comprobantes de una empresa, por fecha.
CREATE INDEX ix_comprobantes_tenant_fecha
    ON comprobantes (tenant_id, fecha_emision DESC);

-- Consulta típica del worker: qué está pendiente de enviar.
CREATE INDEX ix_comprobantes_pendientes
    ON comprobantes (estado, creado_en)
    WHERE estado IN ('FIRMADO', 'ENCOLADO', 'ENVIADO');

-- Búsqueda por los campos propios de cada empresa.
-- Solo vale la pena si de verdad se filtra por ahí.
CREATE INDEX ix_comprobantes_extra ON comprobantes USING gin (extra);

COMMENT ON COLUMN comprobantes.extra IS
    'Campos propios de cada empresa, validados contra su JSON Schema. '
    'NUNCA viajan a SUNAT: el XML se arma solo con la columna cpe.';


-- ===========================================================================
-- BITÁCORA DE ENVÍOS
--
-- Append-only. Responde: qué se envió, de qué RUC, cuándo, cuántas veces,
-- por qué falló y qué respondió SUNAT exactamente.
-- ===========================================================================

CREATE TABLE envio_intentos (
    id                  bigserial   PRIMARY KEY,
    tenant_id           uuid        NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
    comprobante_id      uuid        NOT NULL REFERENCES comprobantes(id) ON DELETE RESTRICT,

    intento_nro         smallint    NOT NULL DEFAULT 1,

    estado_anterior     varchar(30),
    estado_nuevo        varchar(30) NOT NULL,

    codigo_sunat        varchar(10),
    mensaje             text,

    -- La respuesta cruda de SUNAT, tal cual llegó. Parece exagerado hasta
    -- el día que un cliente pregunta por qué se rechazó su factura de hace
    -- tres meses y el código de error por sí solo no alcanza.
    request_raw         text,
    response_raw        text,

    duracion_ms         integer,
    worker              text,

    creado_en           timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX ix_envio_intentos_comprobante
    ON envio_intentos (comprobante_id, creado_en);

CREATE INDEX ix_envio_intentos_tenant_fecha
    ON envio_intentos (tenant_id, creado_en DESC);

-- APPEND-ONLY, GARANTIZADO POR LA BASE.
-- El estado actual vive en comprobantes; la historia no se toca jamás.
-- Confiar en que nadie escriba un UPDATE por error es confiar de más.
CREATE RULE envio_intentos_sin_update AS
    ON UPDATE TO envio_intentos DO INSTEAD NOTHING;

CREATE RULE envio_intentos_sin_delete AS
    ON DELETE TO envio_intentos DO INSTEAD NOTHING;


-- ===========================================================================
-- ROW LEVEL SECURITY
--
-- Esta es la barrera real del aislamiento entre empresas. No es un filtro
-- en el código: es el motor de la base el que hace que las filas de otro
-- tenant NO EXISTAN para la consulta.
--
-- Aunque alguien escriba un SELECT * sin WHERE, solo verá lo suyo.
--
-- La aplicación declara con qué tenant trabaja al abrir la transacción:
--
--     SET LOCAL app.tenant_id = '...uuid...';
--
-- SET LOCAL, no SET: así el valor muere con la transacción y no se filtra
-- a la siguiente petición que reutilice la conexión del pool.
--
-- Si nadie lo declara, current_setting devuelve vacío, la comparación da
-- NULL y no se ve ninguna fila. Falla cerrado, que es como debe fallar.
-- ===========================================================================

CREATE OR REPLACE FUNCTION app_tenant_actual() RETURNS uuid AS $$
    SELECT NULLIF(current_setting('app.tenant_id', true), '')::uuid;
$$ LANGUAGE sql STABLE;

DO $$
DECLARE
    t text;
BEGIN
    FOREACH t IN ARRAY ARRAY['certificados', 'series', 'comprobantes', 'envio_intentos']
    LOOP
        EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', t);

        -- FORCE hace que la política aplique también al dueño de la tabla.
        -- Sin esto, cualquier conexión como owner vería todo.
        EXECUTE format('ALTER TABLE %I FORCE ROW LEVEL SECURITY', t);

        EXECUTE format(
            'CREATE POLICY aislamiento_tenant ON %I
                 USING (tenant_id = app_tenant_actual())
                 WITH CHECK (tenant_id = app_tenant_actual())', t);
    END LOOP;
END
$$;

-- La tabla de tenants no lleva tenant_id: es el catálogo. Solo el operador
-- la administra, y la aplicación la lee para resolver credenciales.


-- ===========================================================================
-- PERMISOS
-- ===========================================================================

GRANT USAGE ON SCHEMA public TO facturacion_app, facturacion_operador;

GRANT SELECT ON tenants TO facturacion_app;
GRANT SELECT, INSERT, UPDATE ON certificados, series, comprobantes TO facturacion_app;
GRANT SELECT, INSERT ON envio_intentos TO facturacion_app;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO facturacion_app;

GRANT ALL ON ALL TABLES IN SCHEMA public TO facturacion_operador;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO facturacion_operador;

-- Nadie borra comprobantes. Anular es un estado, no un DELETE:
-- la obligación legal de conservación se extiende por años.


-- ===========================================================================
-- DISPARADOR DE actualizado_en
-- ===========================================================================

CREATE OR REPLACE FUNCTION marcar_actualizado() RETURNS trigger AS $$
BEGIN
    NEW.actualizado_en = now();
    RETURN NEW;
END
$$ LANGUAGE plpgsql;

CREATE TRIGGER tg_comprobantes_actualizado
    BEFORE UPDATE ON comprobantes
    FOR EACH ROW EXECUTE FUNCTION marcar_actualizado();


-- ===========================================================================
-- DATOS DE PRUEBA
--
-- El mismo RUC que venimos usando contra el ambiente beta.
-- ===========================================================================

INSERT INTO tenants (ruc, razon_social, nombre_comercial, direccion,
                     distrito, provincia, departamento, ambiente,
                     usuario_sol, max_concurrencia)
VALUES ('20601234567', 'MI EMPRESA SAC', 'MI EMPRESA', 'AV. EJEMPLO 123',
        'LIMA', 'LIMA', 'LIMA', 'beta',
        'MODDATOS', 3);


-- NOTA: las contraseñas de este archivo son las iniciales y YA NO SON VÁLIDAS.
-- Se cambiaron con ALTER ROLE y ahora viven en el .env. Una migración es un
-- registro histórico de cómo quedó la base: se deja como está.