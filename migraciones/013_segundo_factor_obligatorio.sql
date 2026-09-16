-- ===========================================================================
-- EL SEGUNDO FACTOR PASA A SER OBLIGATORIO
--
-- POR QUÉ:
--
-- Este panel da acceso a los certificados digitales de todos los clientes.
-- Dejar la protección a criterio de cada usuario significa que, en la
-- práctica, casi nadie la activa: es un paso extra que no da nada a cambio
-- hoy, y solo se echa en falta el día del incidente.
--
-- Al configurarse en el primer ingreso, junto con el cambio de la contraseña
-- provisional, deja de ser una tarea pendiente y pasa a ser parte del alta.
--
-- Los usuarios que ya existen tienen plazo: se les pedirá la próxima vez que
-- entren, pero no se les bloquea de golpe.
-- ===========================================================================

ALTER TABLE usuarios
    ADD COLUMN totp_obligatorio_desde timestamptz;

COMMENT ON COLUMN usuarios.totp_obligatorio_desde IS
    'A partir de cuándo este usuario debe tener segundo factor. NULL '
    'significa que ya lo tiene o que no se le exige todavía.';

-- A los usuarios que ya existen sin segundo factor se les exige desde ya:
-- entrarán, y el panel les pedirá configurarlo antes de dejarles hacer nada.
UPDATE usuarios
   SET totp_obligatorio_desde = now()
 WHERE NOT totp_activo AND activo;
