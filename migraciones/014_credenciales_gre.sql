-- ===========================================================================
-- CREDENCIALES DE LA GUÍA DE REMISIÓN ELECTRÓNICA
--
-- LA GRE USA UN CANAL COMPLETAMENTE DISTINTO al de las facturas:
--
--   Facturas y boletas   SOAP, credenciales SOL, respuesta inmediata con CDR
--   Guías                REST, OAuth2, respuesta con ticket
--
-- Y sus credenciales también son otras. Cada contribuyente genera un
-- client_id y un client_secret desde su menú SOL, en "Credenciales de API
-- SUNAT", una sola vez. Con esos dos valores se pide un token que dura una
-- hora.
--
-- La clave SOL sigue haciendo falta para las facturas, así que una empresa
-- que emita ambas cosas tendrá los dos juegos de credenciales.
--
--
-- UN DATO QUE CAMBIA LA ARQUITECTURA:
--
-- Las GRE NO se pueden emitir a través del SEE-OSE. Van siempre por el
-- sistema del contribuyente. Aunque algún día el servicio se certifique como
-- OSE, las guías seguirían por este camino.
-- ===========================================================================

ALTER TABLE tenants
    ADD COLUMN gre_client_id text,
    ADD COLUMN gre_client_secret_cifrado bytea,

    -- Series propias de la guía, distintas de las de factura.
    --
    -- SUNAT las impone: T### para la guía de remitente y V### para la de
    -- transportista. No es una convención nuestra.
    ADD COLUMN gre_habilitado boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN tenants.gre_client_id IS
    'Generado por el contribuyente en su menú SOL, opción Credenciales de '
    'API SUNAT. No es secreto por sí solo, pero identifica la aplicación.';

COMMENT ON COLUMN tenants.gre_client_secret_cifrado IS
    'Cifrado igual que la clave SOL y el certificado. Con él y el client_id '
    'se obtiene un token que permite emitir guías en nombre de la empresa.';


-- ===========================================================================
-- GUÍAS DE REMISIÓN
--
-- Tabla propia y no una fila más en comprobantes, por tres razones:
--
--   Los datos son otros. Una guía no tiene importes ni IGV: tiene puntos de
--   partida y llegada, transportista, vehículo, conductor y bultos.
--
--   El ciclo es otro. Envío asíncrono con ticket, como el resumen diario,
--   pero por REST y con token que caduca.
--
--   Y hay una regla que no existe en las facturas: LA CDR ACEPTADA DEBE
--   EXISTIR ANTES DE QUE EL CAMIÓN SALGA. Una factura se puede enviar
--   después; una guía no. Eso obliga a que el estado se consulte rápido y a
--   avisar al cliente de inmediato.
-- ===========================================================================

CREATE TABLE guias (
    id                  uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id           uuid        NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,

    -- '09' remitente, '31' transportista.
    tipo_guia           varchar(2)  NOT NULL,

    serie               varchar(4)  NOT NULL,
    correlativo         integer     NOT NULL,

    fecha_emision       date        NOT NULL,
    fecha_traslado      date        NOT NULL,

    -- Catálogo 20: venta, compra, traslado entre establecimientos, etc.
    motivo_traslado     varchar(2)  NOT NULL,

    -- Catálogo 18: 01 transporte público, 02 privado.
    modalidad_traslado  varchar(2)  NOT NULL,

    -- A quién se le envían los bienes.
    destinatario_doc    varchar(15) NOT NULL,
    destinatario_nombre text        NOT NULL,

    peso_bruto          numeric(12,3),
    numero_bultos       integer,

    estado              varchar(30) NOT NULL DEFAULT 'BORRADOR',

    -- SUNAT devuelve un ticket UUID, no un CDR inmediato.
    ticket              varchar(50),

    codigo_sunat        varchar(10),
    mensaje_sunat       text,

    ruta_xml            text,
    ruta_cdr            text,

    -- Igual que en los comprobantes: lo que viaja a SUNAT y lo que no.
    gre                 jsonb       NOT NULL,
    extra               jsonb       NOT NULL DEFAULT '{}',

    idempotency_key     text,

    intentos_fallidos   smallint    NOT NULL DEFAULT 0,
    proximo_intento_en  timestamptz,

    creado_en           timestamptz NOT NULL DEFAULT now(),
    actualizado_en      timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT ux_guias_numero
        UNIQUE (tenant_id, tipo_guia, serie, correlativo),

    CONSTRAINT ux_guias_idempotency
        UNIQUE (tenant_id, idempotency_key),

    CONSTRAINT ck_guias_tipo CHECK (tipo_guia IN ('09', '31')),

    -- SUNAT exige el prefijo de la serie según el tipo.
    CONSTRAINT ck_guias_serie CHECK (
        (tipo_guia = '09' AND serie ~ '^T[0-9]{3}$') OR
        (tipo_guia = '31' AND serie ~ '^V[0-9]{3}$')
    ),

    CONSTRAINT ck_guias_estado CHECK (estado IN (
        'BORRADOR', 'FIRMADO', 'ENCOLADO', 'ENVIADO',
        'ACEPTADO', 'ACEPTADO_CON_OBSERVACIONES', 'RECHAZADO', 'ANULADO'
    )),

    -- El traslado no puede empezar antes de emitir la guía.
    CONSTRAINT ck_guias_fechas CHECK (fecha_traslado >= fecha_emision)
);

CREATE INDEX ix_guias_tenant ON guias (tenant_id, creado_en DESC);

CREATE INDEX ix_guias_pendientes
    ON guias (estado, proximo_intento_en NULLS FIRST, creado_en)
    WHERE estado IN ('BORRADOR', 'ENCOLADO', 'ENVIADO');


-- Series de guías: reutiliza la tabla existente.
--
-- Los tipos 09 y 31 conviven con 01, 03, 07 y 08. El correlativo se reserva
-- igual, con el mismo UPDATE ... RETURNING que ya está probado con 50
-- emisiones simultáneas.


ALTER TABLE guias ENABLE ROW LEVEL SECURITY;
ALTER TABLE guias FORCE ROW LEVEL SECURITY;

CREATE POLICY aislamiento_tenant ON guias
    USING (tenant_id = app_tenant_actual())
    WITH CHECK (tenant_id = app_tenant_actual());

GRANT SELECT, INSERT, UPDATE ON guias TO facturacion_app;
GRANT ALL ON guias TO facturacion_operador;

CREATE TRIGGER tg_guias_actualizado
    BEFORE UPDATE ON guias
    FOR EACH ROW EXECUTE FUNCTION marcar_actualizado();


-- Las series de guía deben admitirse en el CHECK de la tabla series.
ALTER TABLE series DROP CONSTRAINT IF EXISTS ck_series_tipo;

ALTER TABLE series ADD CONSTRAINT ck_series_tipo
    CHECK (tipo_comprobante IN ('01', '03', '07', '08', '09', '31'));
