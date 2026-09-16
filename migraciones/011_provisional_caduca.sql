-- ===========================================================================
-- LA CONTRASEÑA PROVISIONAL CADUCA
--
-- POR QUÉ HACE FALTA:
--
-- Cuando se crea un usuario, su contraseña provisional viaja por correo. Ese
-- correo se queda en la bandeja de entrada, y a veces también en la de
-- enviados de quien lo mandó.
--
-- Si nadie la usa, esa contraseña sigue sirviendo indefinidamente. Alguien
-- que meses después acceda a ese buzón —un equipo robado, una cuenta
-- comprometida— tendría la llave de un panel que da acceso a los
-- certificados de todos los clientes.
--
-- Con caducidad, una contraseña sin usar deja de servir y hay que pedir otra.
-- Es una molestia pequeña que cierra una puerta que nadie vigila.
-- ===========================================================================

ALTER TABLE usuarios
    ADD COLUMN provisional_expira timestamptz;

COMMENT ON COLUMN usuarios.provisional_expira IS
    'Hasta cuándo sirve la contraseña provisional. NULL cuando el usuario ya '
    'eligió la suya.';

-- Los usuarios que ya existen con contraseña provisional reciben plazo desde
-- ahora, no desde que se crearon: no sería justo caducarles algo que hasta
-- hoy no tenía fecha.
UPDATE usuarios
   SET provisional_expira = now() + interval '48 hours'
 WHERE debe_cambiar;
