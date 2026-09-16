-- ===========================================================================
-- RECUPERACIÓN DE CONTRASEÑA
--
-- Se guarda el HASH del enlace, no el enlace.
--
-- Ese enlace llega por correo y permite cambiar la contraseña sin conocer la
-- anterior: es tan poderoso como la contraseña misma mientras esté vigente.
-- Si alguien obtuviera una copia de la base, con los enlaces en claro podría
-- tomar cualquier cuenta que tuviera una recuperación pendiente.
-- ===========================================================================

CREATE TABLE recuperaciones (
    id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    usuario_id  uuid        NOT NULL REFERENCES usuarios(id) ON DELETE CASCADE,

    token_hash  varchar(64) NOT NULL UNIQUE,

    -- Una hora. Suficiente para leer el correo y actuar, corto para que un
    -- enlace olvidado en una bandeja no siga sirviendo semanas después.
    expira_en   timestamptz NOT NULL,

    usado_en    timestamptz,

    -- Desde dónde se pidió. Si alguien recibe un correo que no pidió, esto
    -- es lo que permite averiguar de dónde salió.
    solicitado_desde inet,

    creado_en   timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX ix_recuperaciones_token ON recuperaciones (token_hash)
    WHERE usado_en IS NULL;

CREATE INDEX ix_recuperaciones_usuario
    ON recuperaciones (usuario_id, creado_en DESC);

GRANT SELECT, INSERT, UPDATE ON recuperaciones TO facturacion_operador;
