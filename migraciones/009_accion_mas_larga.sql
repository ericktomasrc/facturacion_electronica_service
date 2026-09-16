-- ===========================================================================
-- LA COLUMNA "accion" ERA DEMASIADO CORTA
--
-- Se declaró como varchar(10) pensando en los métodos HTTP: POST, PATCH,
-- DELETE. Pero después se añadieron acciones propias como RESTABLECER, que
-- tiene once caracteres, y PostgreSQL rechazaba la inserción.
--
-- LA CONSECUENCIA ERA PEOR QUE EL ERROR: la contraseña sí se cambiaba y el
-- correo sí se enviaba, pero al registrar la acción fallaba todo con un 500.
-- El usuario veía un error y creía que no había funcionado, cuando sí.
--
-- La lección: poner límites ajustados a lo que existe hoy parece prolijo y
-- se vuelve una trampa en cuanto aparece un caso nuevo. En una columna de
-- texto corto, unos caracteres de más no cuestan nada.
-- ===========================================================================

ALTER TABLE auditoria
    ALTER COLUMN accion TYPE varchar(30);
