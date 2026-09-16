-- ===========================================================================
-- USUARIOS DEL PANEL
--
-- QUÉ REEMPLAZA: una clave compartida en una variable de entorno.
--
-- Esa clave funcionaba mientras el panel lo usaba una sola persona en su
-- máquina. Deja de funcionar en cuanto hay un segundo usuario, por tres
-- razones concretas:
--
--   No se sabe quién hizo qué. Si alguien revoca una clave o desactiva a un
--   cliente, no hay forma de averiguar quién fue.
--
--   No se le puede quitar el acceso a una persona. Si alguien se va, la
--   única opción es cambiar la clave para todos.
--
--   No hay niveles. Quien entra puede cargar certificados, pasar empresas a
--   producción y revocar accesos. Una persona de soporte no necesita nada
--   de eso.
-- ===========================================================================

-- citext: texto que no distingue mayúsculas de minúsculas.
--
-- Se usa para los correos. Sin esto, "Erick@empresa.pe" y "erick@empresa.pe"
-- serían dos usuarios distintos, y alguien acabaría con dos cuentas sin
-- entender por qué una no funciona.
--
-- La migración inicial solo instaló pgcrypto, así que esta extensión hay que
-- añadirla aquí.
CREATE EXTENSION IF NOT EXISTS citext;


CREATE TABLE usuarios (
    id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),

    correo          citext      NOT NULL UNIQUE,
    nombre          text        NOT NULL DEFAULT '',

    -- Formato: algoritmo$iteraciones$sal$hash, todo en base64.
    --
    -- Se guarda el algoritmo y las iteraciones junto al hash a propósito:
    -- el día que haya que endurecerlo, los usuarios viejos siguen pudiendo
    -- entrar y su contraseña se re-cifra al siguiente ingreso. Sin eso,
    -- cambiar el algoritmo obligaría a restablecer la contraseña de todos.
    contrasena_hash text        NOT NULL,

    -- 'administrador' puede todo.
    -- 'soporte' consulta y reprocesa, pero no toca certificados, no pasa
    -- empresas a producción y no gestiona usuarios.
    rol             varchar(20) NOT NULL DEFAULT 'soporte',

    activo          boolean     NOT NULL DEFAULT true,

    -- Obliga a cambiarla en el primer ingreso. Se usa cuando un
    -- administrador crea o restablece una cuenta: la contraseña provisional
    -- viaja por correo o por chat, así que no debe quedarse.
    debe_cambiar    boolean     NOT NULL DEFAULT false,

    ultimo_ingreso  timestamptz,

    -- Defensa contra el probado sistemático de contraseñas.
    intentos_fallidos smallint  NOT NULL DEFAULT 0,
    bloqueado_hasta timestamptz,

    creado_en       timestamptz NOT NULL DEFAULT now(),
    actualizado_en  timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT ck_usuarios_rol CHECK (rol IN ('administrador', 'soporte'))
);

CREATE TRIGGER tg_usuarios_actualizado
    BEFORE UPDATE ON usuarios
    FOR EACH ROW EXECUTE FUNCTION marcar_actualizado();


-- ===========================================================================
-- SESIONES
--
-- Se guarda el HASH del identificador de sesión, no el identificador.
--
-- Es el mismo criterio que con las contraseñas y las claves de API: si
-- alguien obtiene una copia de la base, no debe poder hacerse pasar por
-- nadie. Con solo el hash, los identificadores robados no sirven.
-- ===========================================================================

CREATE TABLE sesiones (
    id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    usuario_id      uuid        NOT NULL REFERENCES usuarios(id) ON DELETE CASCADE,

    token_hash      varchar(64) NOT NULL UNIQUE,

    -- Para poder responder "¿desde dónde entró esta sesión?" tras un
    -- incidente.
    direccion_ip    inet,
    agente          text,

    expira_en       timestamptz NOT NULL,
    creado_en       timestamptz NOT NULL DEFAULT now(),
    ultimo_uso      timestamptz NOT NULL DEFAULT now(),

    revocada_en     timestamptz
);

CREATE INDEX ix_sesiones_token ON sesiones (token_hash)
    WHERE revocada_en IS NULL;

CREATE INDEX ix_sesiones_usuario ON sesiones (usuario_id, creado_en DESC);


-- ===========================================================================
-- BITÁCORA DE ACCIONES
--
-- Registra TODO lo que modifica algo desde el panel: quién, qué, cuándo y
-- desde dónde.
--
-- POR QUÉ ES APPEND-ONLY, igual que la bitácora de envíos: una bitácora que
-- se puede editar no sirve como bitácora. La pregunta que hay que poder
-- responder después de un incidente es "¿quién hizo esto?", y si el propio
-- responsable pudo borrar el rastro, no hay respuesta.
-- ===========================================================================

CREATE TABLE auditoria (
    id              bigserial   PRIMARY KEY,

    usuario_id      uuid        REFERENCES usuarios(id) ON DELETE SET NULL,
    correo          citext      NOT NULL,

    accion          varchar(10) NOT NULL,
    ruta            text        NOT NULL,

    -- Empresa afectada, cuando la acción es sobre una.
    tenant_id       uuid,

    codigo_respuesta integer    NOT NULL,

    direccion_ip    inet,
    agente          text,

    creado_en       timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX ix_auditoria_usuario ON auditoria (usuario_id, creado_en DESC);
CREATE INDEX ix_auditoria_fecha ON auditoria (creado_en DESC);
CREATE INDEX ix_auditoria_tenant ON auditoria (tenant_id, creado_en DESC)
    WHERE tenant_id IS NOT NULL;

CREATE RULE auditoria_sin_update AS ON UPDATE TO auditoria DO INSTEAD NOTHING;
CREATE RULE auditoria_sin_delete AS ON DELETE TO auditoria DO INSTEAD NOTHING;


-- ===========================================================================
-- PERMISOS
--
-- Estas tablas NO llevan Row Level Security: no pertenecen a ninguna empresa,
-- son de la plataforma. El acceso se controla por rol dentro de la aplicación.
-- ===========================================================================

GRANT SELECT, INSERT, UPDATE ON usuarios TO facturacion_operador;
GRANT SELECT, INSERT, UPDATE ON sesiones TO facturacion_operador;
GRANT SELECT, INSERT ON auditoria TO facturacion_operador;
GRANT USAGE, SELECT ON SEQUENCE auditoria_id_seq TO facturacion_operador;

-- La aplicación normal no toca nada de esto: el panel usa el rol de operador.
