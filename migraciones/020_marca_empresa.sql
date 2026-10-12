-- ===========================================================================
-- 020 — La marca de cada empresa
--
-- POR QUÉ HACE FALTA:
--
-- El portal del receptor (comprobantes.reyban.pe/{empresa}) y el correo de
-- entrega tienen que verse DEL EMISOR, no de Reyban: su logo, su color, y
-- las respuestas del cliente tienen que llegarle a él. Nada de eso existía
-- en `tenants`.
--
--
-- LAS CUATRO COLUMNAS:
--
--   identificador     El {empresa} de la dirección pública. Minúsculas,
--                     dígitos y guiones, 3 a 40 caracteres, único.
--                     NO SE PUEDE CAMBIAR UNA VEZ PUESTO: es la dirección
--                     que va impresa en cada correo enviado. Cambiarla
--                     rompería todos los enlaces que ya están en bandejas de
--                     entrada. Lo impide el disparador de abajo, no la buena
--                     voluntad del panel.
--
--   logo_ruta         Dónde está el logo en el almacén de archivos (el mismo
--                     de los XML). Cada logo nuevo es un archivo nuevo: el
--                     anterior no se borra, solo deja de apuntarse.
--
--   color_marca       #rrggbb en minúsculas. Un solo color.
--
--   correo_respuesta  A dónde van las respuestas a los correos de entrega.
--
--
-- LAS COMPROBACIONES DE LA BASE SON LA ÚLTIMA BARRERA. Las que devuelven un
-- mensaje que se entiende están en la API (Facturacion.Api/Marca.cs). Aquí
-- se ataja lo que nunca puede ser válido, venga de donde venga.
--
-- No necesita GRANT nuevo: los permisos sobre `tenants` son de tabla entera
-- e incluyen las columnas que se añadan.
-- ===========================================================================

BEGIN;

ALTER TABLE tenants ADD COLUMN IF NOT EXISTS identificador    text;
ALTER TABLE tenants ADD COLUMN IF NOT EXISTS logo_ruta        text;
ALTER TABLE tenants ADD COLUMN IF NOT EXISTS color_marca      text;
ALTER TABLE tenants ADD COLUMN IF NOT EXISTS correo_respuesta text;

ALTER TABLE tenants DROP CONSTRAINT IF EXISTS ck_tenants_identificador;
ALTER TABLE tenants ADD CONSTRAINT ck_tenants_identificador
    CHECK (
        identificador IS NULL OR (
            identificador ~ '^[a-z0-9][a-z0-9-]{1,38}[a-z0-9]$'
            AND identificador !~ '--'
            -- Palabras que ya usa o usará la dirección del portal.
            AND identificador NOT IN ('api', 'e', 'portal', 'admin', 'www',
                                      'static', 'assets', 'health', 'docs')
        )
    );

ALTER TABLE tenants DROP CONSTRAINT IF EXISTS ck_tenants_color_marca;
ALTER TABLE tenants ADD CONSTRAINT ck_tenants_color_marca
    CHECK (color_marca IS NULL OR color_marca ~ '^#[0-9a-f]{6}$');

ALTER TABLE tenants DROP CONSTRAINT IF EXISTS ck_tenants_correo_respuesta;
ALTER TABLE tenants ADD CONSTRAINT ck_tenants_correo_respuesta
    CHECK (
        correo_respuesta IS NULL OR (
            length(correo_respuesta) BETWEEN 3 AND 254
            AND correo_respuesta !~ '\s'
            AND position('@' IN correo_respuesta) > 1
        )
    );

ALTER TABLE tenants DROP CONSTRAINT IF EXISTS ck_tenants_logo_ruta;
ALTER TABLE tenants ADD CONSTRAINT ck_tenants_logo_ruta
    CHECK (logo_ruta IS NULL OR length(logo_ruta) BETWEEN 1 AND 500);

-- Único entre las que lo tienen. Las empresas antiguas sin identificador
-- pueden ser muchas: NULL no choca con NULL.
CREATE UNIQUE INDEX IF NOT EXISTS ux_tenants_identificador
    ON tenants (identificador)
    WHERE identificador IS NOT NULL;

-- El identificador se puede poner una vez y ya no se toca: ni cambiarlo ni
-- quitarlo. Los mensajes van sin tildes porque PowerShell 5.1 manda este
-- archivo a psql en ASCII.
CREATE OR REPLACE FUNCTION tenants_identificador_inmutable()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF OLD.identificador IS NOT NULL
       AND NEW.identificador IS DISTINCT FROM OLD.identificador THEN
        RAISE EXCEPTION
            'El identificador del portal de la empresa % ya es "%" y no se puede cambiar.',
            OLD.ruc, OLD.identificador
            USING ERRCODE = 'P0001',
                  HINT = 'Es la direccion que va en los correos ya enviados.';
    END IF;

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS tr_tenants_identificador_inmutable ON tenants;

CREATE TRIGGER tr_tenants_identificador_inmutable
    BEFORE UPDATE OF identificador ON tenants
    FOR EACH ROW
    EXECUTE FUNCTION tenants_identificador_inmutable();

COMMENT ON COLUMN tenants.identificador IS
    'El {empresa} de comprobantes.reyban.pe/{empresa}. Unico. No se cambia una vez puesto.';
COMMENT ON COLUMN tenants.logo_ruta IS
    'Ruta del logo en el almacen de archivos. PNG o JPG, maximo 300 KB.';
COMMENT ON COLUMN tenants.color_marca IS
    'Color de la marca, #rrggbb en minusculas. Botones y cabecera del portal.';
COMMENT ON COLUMN tenants.correo_respuesta IS
    'Responder-a de los correos de entrega. Sin el, no se mandan correos.';

COMMIT;