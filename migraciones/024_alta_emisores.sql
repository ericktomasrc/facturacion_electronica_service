-- ===========================================================================
-- 024 — El alta de un emisor desde la plataforma
--
-- Diseño: alta-empresa-diseno.md §13 (aprobado el 11 de octubre).
--
-- QUÉ CAMBIA: hasta hoy un emisor solo nacía en el panel del servicio. Desde
-- ahora la plataforma también puede crearlo, con una credencial que SOLO
-- crea: la clave de alta (alt_). No lee, no lista y no modifica ninguna
-- empresa existente.
--
--
-- LO QUE AÑADE:
--
--   claves_alta              Las claves de alta. Como api_keys: solo el hash.
--                            Cada una con su tope de altas por día (20).
--
--   tenants.estado_alta      sin_confirmar · confirmada · abandonada
--                            Dos bases sin transacción común: el servicio crea
--                            el emisor «sin confirmar», la plataforma guarda lo
--                            suyo y después confirma. Si la plataforma no llega
--                            a guardar, el emisor se queda sin confirmar y el
--                            siguiente intento lo da por abandonado. Las que ya
--                            existen pasan a «confirmada» (las creaste tú).
--
--   tenants.direccion_revisada_en
--                            Cuándo escribió alguien la dirección a propósito.
--                            Una dirección por defecto (LIMA) no se distingue
--                            de una revisada: esta columna es la diferencia.
--                            NULA en las que ya existen, porque es la verdad:
--                            nadie la revisó.
--
--   El RUC                   Era único PARA SIEMPRE (tenants_ruc_key). Un emisor
--                            abandonado bloquearía ese RUC sin remedio. Ahora es
--                            único entre los que no están abandonados.
--
--   altas.gestionar          Permiso nuevo: emitir y revocar claves de alta.
--
--
-- NADA SE BORRA: un emisor abandonado se desactiva, su clave se revoca y su
-- webhook se apaga. La fila queda, con la fecha.
--
-- Los mensajes de error van sin tildes: PowerShell 5.1 manda este archivo a
-- psql en ASCII.
-- ===========================================================================

BEGIN;

-- --- claves_alta -----------------------------------------------------------

CREATE TABLE IF NOT EXISTS claves_alta (
    id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    nombre          text        NOT NULL,

    -- Los 20 primeros caracteres, como api_keys.prefijo: para reconocerla en
    -- el panel y en la bitacora sin poder usarla.
    prefijo         varchar(20) NOT NULL,
    hash            varchar(64) NOT NULL,

    -- Altas por dia de Lima. Si se filtra, el dano queda acotado a esto.
    tope_diario     smallint    NOT NULL DEFAULT 20,

    activo          boolean     NOT NULL DEFAULT true,
    creado_en       timestamptz NOT NULL DEFAULT now(),
    creado_por      uuid        REFERENCES usuarios(id) ON DELETE RESTRICT,
    ultimo_uso      timestamptz,
    revocado_en     timestamptz,
    revocado_por    uuid        REFERENCES usuarios(id) ON DELETE RESTRICT,

    -- El ultimo dia en que se mando el correo de «tope alcanzado». Uno al dia.
    tope_avisado_en timestamptz,

    CONSTRAINT ux_claves_alta_hash UNIQUE (hash),
    CONSTRAINT ck_claves_alta_nombre CHECK (length(btrim(nombre)) BETWEEN 1 AND 100),
    CONSTRAINT ck_claves_alta_prefijo CHECK (prefijo LIKE 'alt\_%'),
    CONSTRAINT ck_claves_alta_tope CHECK (tope_diario BETWEEN 1 AND 100),
    CONSTRAINT ck_claves_alta_revocada CHECK (activo OR revocado_en IS NOT NULL)
);

COMMENT ON TABLE claves_alta IS
    'Claves con las que la plataforma crea emisores (POST /alta/emisores). Solo crean: '
    'no leen ni cambian empresas existentes. Solo el hash. Nada se borra.';

-- Solo el operador (el panel y la ruta de alta). La aplicacion no las ve.
GRANT SELECT, INSERT, UPDATE ON claves_alta TO facturacion_operador;
REVOKE DELETE, TRUNCATE ON claves_alta FROM facturacion_operador;


-- --- tenants: el estado del alta -------------------------------------------

ALTER TABLE tenants ADD COLUMN IF NOT EXISTS estado_alta           text;
ALTER TABLE tenants ADD COLUMN IF NOT EXISTS alta_confirmada_en    timestamptz;
ALTER TABLE tenants ADD COLUMN IF NOT EXISTS abandonada_en         timestamptz;
ALTER TABLE tenants ADD COLUMN IF NOT EXISTS creado_por_clave_alta uuid
    REFERENCES claves_alta(id) ON DELETE RESTRICT;
ALTER TABLE tenants ADD COLUMN IF NOT EXISTS direccion_revisada_en timestamptz;

-- LAS QUE YA EXISTEN, CONFIRMADAS. Las creaste tu en el panel: no hay nada
-- que confirmar, y en «sin confirmar» quedarian a tiro de darse por
-- abandonadas. creado_por_clave_alta queda nulo: no las creo ninguna clave.
UPDATE tenants SET estado_alta = 'confirmada' WHERE estado_alta IS NULL;

-- Por defecto «confirmada»: es lo que debe ser un alta del panel. La ruta de
-- alta pone «sin_confirmar» a proposito, nunca por omision.
ALTER TABLE tenants ALTER COLUMN estado_alta SET DEFAULT 'confirmada';
ALTER TABLE tenants ALTER COLUMN estado_alta SET NOT NULL;

ALTER TABLE tenants DROP CONSTRAINT IF EXISTS ck_tenants_estado_alta;
ALTER TABLE tenants ADD CONSTRAINT ck_tenants_estado_alta
    CHECK (estado_alta IN ('sin_confirmar', 'confirmada', 'abandonada'));

-- Abandonada = desactivada y con fecha. Sin las dos cosas no es abandonada.
ALTER TABLE tenants DROP CONSTRAINT IF EXISTS ck_tenants_abandonada;
ALTER TABLE tenants ADD CONSTRAINT ck_tenants_abandonada
    CHECK (estado_alta <> 'abandonada' OR (NOT activo AND abandonada_en IS NOT NULL));

-- Solo una clave de alta crea emisores sin confirmar.
ALTER TABLE tenants DROP CONSTRAINT IF EXISTS ck_tenants_sin_confirmar;
ALTER TABLE tenants ADD CONSTRAINT ck_tenants_sin_confirmar
    CHECK (estado_alta <> 'sin_confirmar' OR creado_por_clave_alta IS NOT NULL);

-- Las vueltas que se permiten, y ninguna mas:
--   sin_confirmar -> confirmada   la plataforma confirmo
--   sin_confirmar -> abandonada   un alta posterior del mismo RUC
-- Y una abandonada no se reactiva nunca: su RUC ya puede tenerlo otra.
CREATE OR REPLACE FUNCTION tenants_estado_alta_transicion()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF OLD.estado_alta = 'abandonada' AND NEW.activo THEN
        RAISE EXCEPTION
            'La empresa % es un alta abandonada y no se puede reactivar.', OLD.ruc
            USING ERRCODE = 'P0001',
                  HINT = 'Su RUC puede estar ya en otra empresa. Da de alta una nueva.';
    END IF;

    IF NEW.estado_alta IS NOT DISTINCT FROM OLD.estado_alta THEN
        RETURN NEW;
    END IF;

    IF OLD.estado_alta = 'sin_confirmar'
       AND NEW.estado_alta IN ('confirmada', 'abandonada') THEN
        RETURN NEW;
    END IF;

    RAISE EXCEPTION
        'La empresa % no puede pasar de % a %.', OLD.ruc, OLD.estado_alta, NEW.estado_alta
        USING ERRCODE = 'P0001';
END;
$$;

DROP TRIGGER IF EXISTS tr_tenants_estado_alta ON tenants;

CREATE TRIGGER tr_tenants_estado_alta
    BEFORE UPDATE OF estado_alta, activo ON tenants
    FOR EACH ROW
    EXECUTE FUNCTION tenants_estado_alta_transicion();


-- --- El RUC: unico entre los que no estan abandonados ----------------------

CREATE UNIQUE INDEX IF NOT EXISTS ux_tenants_ruc_vigente
    ON tenants (ruc)
    WHERE estado_alta <> 'abandonada';

ALTER TABLE tenants DROP CONSTRAINT IF EXISTS tenants_ruc_key;

-- Para contar las altas del dia de cada clave (el tope).
CREATE INDEX IF NOT EXISTS ix_tenants_clave_alta
    ON tenants (creado_por_clave_alta, creado_en)
    WHERE creado_por_clave_alta IS NOT NULL;


-- --- webhook_cambios: los que nacen con el alta ----------------------------

ALTER TABLE webhook_cambios DROP CONSTRAINT IF EXISTS ck_webhook_cambios_desde;
ALTER TABLE webhook_cambios ADD CONSTRAINT ck_webhook_cambios_desde
    CHECK (hecho_desde IN ('api', 'panel', 'alta'));


-- --- El permiso ------------------------------------------------------------

INSERT INTO permisos (clave, area, nombre, descripcion, orden) VALUES
-- Con U&'...' y escapes: el area tiene que ser EXACTAMENTE 'Crítico', la de
-- certificados y produccion, y las tildes no sobreviven al viaje en ASCII.
('altas.gestionar', U&'Cr\00EDtico', 'Emitir y revocar claves de alta',
 'La clave con la que la plataforma crea emisores nuevos. Solo crea: no lee ' ||
 U&'ni cambia los existentes. Si se filtra, alguien podr\00EDa ocupar el RUC ' ||
 'de un cliente.', 42)
ON CONFLICT (clave) DO NOTHING;

INSERT INTO rol_permisos (rol_id, permiso)
SELECT r.id, 'altas.gestionar' FROM roles r WHERE r.clave = 'administrador'
ON CONFLICT DO NOTHING;


COMMENT ON COLUMN tenants.estado_alta IS
    'sin_confirmar (la creo una clave de alta y la plataforma todavia no confirmo) · '
    'confirmada · abandonada (desactivada para siempre; su RUC queda libre).';
COMMENT ON COLUMN tenants.direccion_revisada_en IS
    'Cuando escribio alguien la direccion a proposito. Nula = nadie la reviso.';
COMMENT ON COLUMN tenants.creado_por_clave_alta IS
    'La clave de alta que la creo. Nula = creada en el panel.';


-- --- Comprobaciones: si algo no quedo como debe, no se confirma nada --------

DO $$
DECLARE
    n integer;
BEGIN
    SELECT count(*) INTO n FROM tenants WHERE estado_alta <> 'confirmada';
    IF n > 0 THEN
        RAISE EXCEPTION 'Hay % empresas que no quedaron confirmadas.', n;
    END IF;

    SELECT count(*) INTO n FROM tenants WHERE creado_por_clave_alta IS NOT NULL;
    IF n > 0 THEN
        RAISE EXCEPTION 'Hay % empresas con clave de alta y no deberia haber ninguna.', n;
    END IF;

    IF EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'tenants_ruc_key') THEN
        RAISE EXCEPTION 'tenants_ruc_key sigue existiendo.';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'ux_tenants_ruc_vigente') THEN
        RAISE EXCEPTION 'Falta ux_tenants_ruc_vigente.';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM rol_permisos rp JOIN roles r ON r.id = rp.rol_id
         WHERE r.clave = 'administrador' AND rp.permiso = 'altas.gestionar') THEN
        RAISE EXCEPTION 'El administrador no tiene altas.gestionar.';
    END IF;

    RAISE NOTICE '024: % empresas confirmadas, RUC unico entre las vigentes, permiso listo.',
        (SELECT count(*) FROM tenants);
END;
$$;

COMMIT;