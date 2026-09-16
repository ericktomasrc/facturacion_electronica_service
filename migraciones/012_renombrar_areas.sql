-- ===========================================================================
-- LOS PERMISOS DE ÁREA DEJAN DE LLAMARSE PSE Y OSE
--
-- POR QUÉ SE CAMBIA:
--
-- PSE y OSE son figuras que define SUNAT: un Proveedor y un Operador de
-- Servicios Electrónicos son entidades registradas, con requisitos legales.
--
-- Usar esos nombres para permisos internos confunde. Alguien que vea
-- "Soporte OSE" en una lista de usuarios puede entender que esa persona, o
-- la empresa, tiene esa condición ante SUNAT. En un ámbito donde los nombres
-- tienen efectos legales, esa confusión no conviene.
--
-- Se nombran por lo que HACEN: emisión y validación.
--
--
-- POR QUÉ NO SE RENOMBRA DIRECTAMENTE:
--
-- Un UPDATE sobre permisos.clave falla, porque rol_permisos lo referencia y
-- PostgreSQL comprueba las claves foráneas EN CADA SENTENCIA, no al final de
-- la transacción. Ni siquiera dentro de un bloque: para eso habría que
-- declarar la restricción como DEFERRABLE, y no lo es.
--
-- La secuencia que sí funciona es: crear los nuevos, mover las referencias,
-- borrar los viejos. Cada paso deja la base en un estado válido.
-- ===========================================================================

BEGIN;

-- 1. Los permisos nuevos.
INSERT INTO permisos (clave, area, nombre, descripcion, orden) VALUES
('emision.ver', 'Áreas', 'Área de emisión',
 'Empresas para las que emitimos nosotros con su certificado digital.', 60),

('validacion.ver', 'Áreas', 'Área de validación',
 'Empresas que emiten solas y cuyos comprobantes validamos. Todavía en '
 'construcción.', 61)
ON CONFLICT (clave) DO NOTHING;

-- 2. Mover las referencias de los roles.
--
-- ON CONFLICT porque si alguien ya tenía los dos, insertar duplicaría.
INSERT INTO rol_permisos (rol_id, permiso)
SELECT rol_id, 'emision.ver' FROM rol_permisos WHERE permiso = 'pse.ver'
ON CONFLICT DO NOTHING;

INSERT INTO rol_permisos (rol_id, permiso)
SELECT rol_id, 'validacion.ver' FROM rol_permisos WHERE permiso = 'ose.ver'
ON CONFLICT DO NOTHING;

DELETE FROM rol_permisos WHERE permiso IN ('pse.ver', 'ose.ver');

-- 3. Ya nadie los referencia: se pueden borrar.
DELETE FROM permisos WHERE clave IN ('pse.ver', 'ose.ver');

-- 4. Los roles.
--
-- Estos sí se renombran en sitio: nada referencia a roles.clave.
UPDATE roles
   SET clave = 'soporte_emision',
       nombre = 'Soporte de emisión',
       descripcion = 'Atiende a las empresas para las que emitimos: consulta '
                     'comprobantes, reprocesa envíos y revisa el estado del '
                     'servicio.'
 WHERE clave = 'soporte_pse';

UPDATE roles
   SET clave = 'soporte_validacion',
       nombre = 'Soporte de validación',
       descripcion = 'Atiende a las empresas cuyos comprobantes validamos. '
                     'Cuando ese módulo exista.'
 WHERE clave = 'soporte_ose';

COMMIT;


-- ===========================================================================
-- COMPROBACIÓN
--
-- Debe devolver los dos permisos nuevos y ninguno de los viejos.
-- ===========================================================================

SELECT clave, nombre FROM permisos WHERE area = 'Áreas' ORDER BY orden;
SELECT clave, nombre FROM roles ORDER BY nombre;
