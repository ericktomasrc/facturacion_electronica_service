-- ===========================================================================
-- SEGUNDO FACTOR
--
-- POR QUÉ EN ESTE PANEL Y NO EN OTROS:
--
-- Quien entra aquí puede cargar el certificado digital de cualquier cliente,
-- pasar empresas a producción y revocar accesos. Una contraseña robada no
-- debería bastar para eso.
--
-- El segundo factor convierte "alguien sabe tu contraseña" en "alguien sabe
-- tu contraseña Y tiene tu teléfono", que es un salto enorme por muy poco
-- trabajo.
-- ===========================================================================

ALTER TABLE usuarios
    -- El secreto compartido con la aplicación autenticadora.
    --
    -- VA CIFRADO, igual que los certificados. Si alguien obtiene una copia
    -- de la base, con el secreto en claro podría generar códigos válidos y
    -- el segundo factor dejaría de servir para nada.
    ADD COLUMN totp_secreto_cifrado bytea,

    ADD COLUMN totp_activo boolean NOT NULL DEFAULT false,

    -- Último periodo de 30 segundos que se usó.
    --
    -- Impide reutilizar un código dentro de su ventana de validez. Sin esto,
    -- quien viera el código por encima del hombro tendría hasta 90 segundos
    -- para usarlo.
    ADD COLUMN totp_ultimo_periodo bigint;


-- ===========================================================================
-- CÓDIGOS DE RECUPERACIÓN
--
-- POR QUÉ SON IMPRESCINDIBLES:
--
-- Los teléfonos se pierden, se rompen y se cambian. Sin una salida, perder
-- el teléfono significa quedarse fuera del sistema para siempre, y en un
-- panel de administración eso puede significar no poder atender a un cliente
-- el día que más falta hace.
--
-- Se guardan como hash y son de un solo uso, igual que las contraseñas.
-- ===========================================================================

CREATE TABLE codigos_recuperacion (
    id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    usuario_id  uuid        NOT NULL REFERENCES usuarios(id) ON DELETE CASCADE,

    codigo_hash varchar(64) NOT NULL,

    usado_en    timestamptz,
    creado_en   timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX ix_recuperacion_usuario
    ON codigos_recuperacion (usuario_id) WHERE usado_en IS NULL;

CREATE UNIQUE INDEX ux_recuperacion_hash
    ON codigos_recuperacion (usuario_id, codigo_hash);


GRANT SELECT, INSERT, UPDATE, DELETE ON codigos_recuperacion TO facturacion_operador;


-- ===========================================================================
-- CORRECCIÓN: la bitácora ya no referencia al usuario
--
-- La referencia con ON DELETE SET NULL choca con la regla que anula los
-- UPDATE sobre la tabla: al borrar un usuario, PostgreSQL intenta poner el
-- campo en nulo, la regla lo impide, y la operación falla entera.
--
-- Se quita la referencia. El correo ya queda guardado en cada fila, así que
-- la bitácora sigue diciendo quién hizo qué aunque la cuenta se elimine.
--
-- De hecho es mejor así: una bitácora que pierde el nombre cuando se borra
-- la cuenta no sirve para investigar precisamente el caso que más importa.
-- ===========================================================================

ALTER TABLE auditoria DROP CONSTRAINT IF EXISTS auditoria_usuario_id_fkey;
