-- ===========================================================================
-- PERMISOS Y ROLES
--
-- QUÉ REEMPLAZA: dos roles fijos escritos en el código, 'administrador' y
-- 'soporte'.
--
-- Eso obligaba a tocar código para crear un rol nuevo, y a elegir entre dos
-- opciones que rara vez encajan: quien da de alta clientes no necesita ver
-- certificados, y quien atiende llamadas no necesita crear empresas.
--
-- Ahora los permisos son datos, los roles los agrupan, y ambos se gestionan
-- desde el panel.
--
-- POR QUÉ POR ROL Y NO POR USUARIO: cuando entre la tercera persona de
-- soporte, se le asigna un rol y listo, en vez de marcar diez casillas una
-- por una y arriesgarse a olvidar alguna. Y el día que soporte deba ver algo
-- más, se cambia en el rol y se aplica a todos a la vez.
-- ===========================================================================

CREATE TABLE permisos (
    clave       varchar(50) PRIMARY KEY,
    area        varchar(30) NOT NULL,
    nombre      text        NOT NULL,
    descripcion text        NOT NULL DEFAULT '',

    -- Para ordenar la lista en el panel de forma legible.
    orden       smallint    NOT NULL DEFAULT 0
);

COMMENT ON TABLE permisos IS
    'Catálogo fijo. Se amplía con migraciones cuando el sistema gana '
    'funcionalidad, no desde el panel: un permiso sin código que lo '
    'compruebe no protege nada.';


CREATE TABLE roles (
    id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    clave       varchar(40) NOT NULL UNIQUE,
    nombre      text        NOT NULL,
    descripcion text        NOT NULL DEFAULT '',

    -- Los roles del sistema no se pueden borrar ni editar.
    --
    -- Solo 'administrador' lo es. Si se le pudieran quitar permisos, alguien
    -- podría dejar el panel sin nadie capaz de administrarlo, y no habría
    -- forma de recuperarlo desde dentro.
    del_sistema boolean     NOT NULL DEFAULT false,

    creado_en   timestamptz NOT NULL DEFAULT now()
);


CREATE TABLE rol_permisos (
    rol_id      uuid        NOT NULL REFERENCES roles(id) ON DELETE CASCADE,
    permiso     varchar(50) NOT NULL REFERENCES permisos(clave) ON DELETE CASCADE,

    PRIMARY KEY (rol_id, permiso)
);


-- ===========================================================================
-- CATÁLOGO DE PERMISOS
-- ===========================================================================

INSERT INTO permisos (clave, area, nombre, descripcion, orden) VALUES

('diagnostico.ver', 'Operación', 'Ver el estado del servicio',
 'Semáforo, alertas, errores frecuentes y certificados por vencer.', 10),

('comprobantes.ver', 'Comprobantes', 'Consultar comprobantes',
 'Buscar, ver el detalle y descargar XML, CDR y PDF de cualquier empresa.', 20),

('comprobantes.reprocesar', 'Comprobantes', 'Reprocesar comprobantes',
 'Devolver a la cola los que fallaron. No modifica su contenido.', 21),

('empresas.ver', 'Empresas', 'Ver empresas',
 'Listado y detalle de las empresas emisoras.', 30),

('empresas.editar', 'Empresas', 'Crear y editar empresas',
 'Dar de alta, activar, desactivar y gestionar sus series.', 31),

('claves.gestionar', 'Empresas', 'Emitir y revocar claves de acceso',
 'Las claves con las que cada empresa consume la API.', 32),

('webhooks.gestionar', 'Empresas', 'Configurar webhooks',
 'A qué dirección se avisa a cada cliente. Quien cambie esa URL puede '
 'redirigir sus datos de facturación.', 33),

('certificados.gestionar', 'Crítico', 'Cargar certificados digitales',
 'La llave con la que se firma en nombre del cliente. Es el permiso más '
 'delicado del sistema.', 40),

('produccion.cambiar', 'Crítico', 'Pasar empresas a producción',
 'A partir de ahí los comprobantes tienen valor legal y los correlativos '
 'consumidos no se recuperan.', 41),

('usuarios.gestionar', 'Plataforma', 'Gestionar usuarios y roles',
 'Crear cuentas, asignar roles y definir qué puede hacer cada uno.', 50),

('auditoria.ver', 'Plataforma', 'Ver la bitácora de acciones',
 'Quién hizo qué, cuándo y desde dónde.', 51),

-- Áreas del producto. Separan qué parte del sistema ve cada persona.
('pse.ver', 'Áreas', 'Área de emisión (PSE)',
 'Empresas para las que emitimos nosotros con su certificado.', 60),

('ose.ver', 'Áreas', 'Área de validación (OSE)',
 'Empresas que emiten solas y cuyos comprobantes validamos. Todavía en '
 'construcción.', 61);


-- ===========================================================================
-- ROLES POR DEFECTO
-- ===========================================================================

INSERT INTO roles (clave, nombre, descripcion, del_sistema) VALUES

('administrador', 'Administrador',
 'Todos los permisos. No se puede editar ni borrar para que el panel nunca '
 'quede sin quien lo administre.', true),

('operaciones', 'Operaciones',
 'Da de alta clientes: empresas, series, claves y webhooks. No toca '
 'certificados ni pasa a producción.', false),

('soporte_pse', 'Soporte PSE',
 'Atiende a las empresas emisoras: consulta comprobantes, reprocesa envíos '
 'y revisa el estado del servicio.', false),

('soporte_ose', 'Soporte OSE',
 'Atiende el área de validación. Cuando ese módulo exista.', false),

('auditor', 'Auditor',
 'Solo lectura de todo, incluida la bitácora. No modifica nada.', false);


-- Administrador: todo.
INSERT INTO rol_permisos (rol_id, permiso)
SELECT r.id, p.clave FROM roles r CROSS JOIN permisos p
 WHERE r.clave = 'administrador';

INSERT INTO rol_permisos (rol_id, permiso)
SELECT r.id, p.clave FROM roles r, permisos p
 WHERE r.clave = 'operaciones'
   AND p.clave IN ('diagnostico.ver', 'comprobantes.ver',
                   'comprobantes.reprocesar', 'empresas.ver', 'empresas.editar',
                   'claves.gestionar', 'webhooks.gestionar', 'pse.ver');

INSERT INTO rol_permisos (rol_id, permiso)
SELECT r.id, p.clave FROM roles r, permisos p
 WHERE r.clave = 'soporte_pse'
   AND p.clave IN ('diagnostico.ver', 'comprobantes.ver',
                   'comprobantes.reprocesar', 'empresas.ver', 'pse.ver');

INSERT INTO rol_permisos (rol_id, permiso)
SELECT r.id, p.clave FROM roles r, permisos p
 WHERE r.clave = 'soporte_ose'
   AND p.clave IN ('diagnostico.ver', 'comprobantes.ver', 'empresas.ver',
                   'ose.ver');

INSERT INTO rol_permisos (rol_id, permiso)
SELECT r.id, p.clave FROM roles r, permisos p
 WHERE r.clave = 'auditor'
   AND p.clave IN ('diagnostico.ver', 'comprobantes.ver', 'empresas.ver',
                   'auditoria.ver', 'pse.ver', 'ose.ver');


-- ===========================================================================
-- LOS USUARIOS PASAN A TENER UN ROL DE LA TABLA
-- ===========================================================================

ALTER TABLE usuarios ADD COLUMN rol_id uuid REFERENCES roles(id);

-- Se conservan los roles que ya tenían.
UPDATE usuarios u
   SET rol_id = (SELECT id FROM roles WHERE clave = 'administrador')
 WHERE u.rol = 'administrador';

UPDATE usuarios u
   SET rol_id = (SELECT id FROM roles WHERE clave = 'soporte_pse')
 WHERE u.rol = 'soporte' OR u.rol_id IS NULL;

ALTER TABLE usuarios ALTER COLUMN rol_id SET NOT NULL;

-- La columna de texto se queda por ahora, sin usarse.
--
-- Borrarla en la misma migración que la reemplaza impide volver atrás si algo
-- sale mal. Se elimina más adelante, cuando el sistema lleve tiempo
-- funcionando con la nueva.
ALTER TABLE usuarios ALTER COLUMN rol DROP NOT NULL;

COMMENT ON COLUMN usuarios.rol IS
    'OBSOLETA. La sustituye rol_id. Se conserva para poder volver atrás; '
    'se eliminará en una migración futura.';


CREATE INDEX ix_usuarios_rol ON usuarios (rol_id);

GRANT SELECT ON permisos TO facturacion_operador;
GRANT SELECT, INSERT, UPDATE, DELETE ON roles TO facturacion_operador;
GRANT SELECT, INSERT, DELETE ON rol_permisos TO facturacion_operador;
