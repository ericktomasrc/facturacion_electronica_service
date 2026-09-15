# Secretos: qué cambió y qué tienes que hacer

## Qué cambió

Las contraseñas y la clave del panel salieron de `appsettings.json`, que se
versiona, y pasaron a un archivo `.env` que no.

| Antes | Ahora |
|---|---|
| Contraseñas en `appsettings.json` | En `.env`, fuera de Git |
| Llave maestra en `launchSettings.json` | En `.env` |
| Clave de operador en `appsettings.json` | En `.env` |
| `appsettings.json` versionado con secretos | Versionado, sin secretos |

## Qué tienes que hacer, en orden

**1. Crea el `.env`** en la raíz de la solución, copiando `.env.ejemplo`, y
rellena los valores. La llave maestra debe ser **la misma que ya usabas**, o
los certificados guardados no se podrán descifrar:

```
FACTURACION_LLAVE_MAESTRA=1+QZmOPbcU8iTb4QufsvtBaoorHh2uSwSdTtYg68VIw=
```

**2. Añade al `.gitignore`:**

```
.env
.env.*
!.env.ejemplo
```

**3. Quita la llave maestra de los `launchSettings.json`** de la API y del
worker. Ahora se lee del `.env`, y tenerla en dos sitios lleva a que un día
difieran sin que nadie lo note.

**4. Comprueba que no quede nada en el repositorio:**

```powershell
git grep -n "cambiame_en_produccion"
git grep -n "operador-dev-2026"
```

Si alguno aparece en un archivo versionado, sácalo.

## Sobre el historial de Git

Las contraseñas que usaste hasta hoy **están en el historial**, y borrarlas
del archivo actual no las borra de ahí: un `git log -p` las sigue mostrando.

Como son de desarrollo y el repositorio es tuyo, no es grave. Pero la lección
sí importa: **una contraseña que llegó a un commit hay que considerarla
comprometida y cambiarla de verdad**, no solo quitarla del archivo.

Si quieres cambiarlas ahora:

```powershell
docker exec -it facturacion-db psql -U facturacion_owner -d facturacion `
  -c "ALTER ROLE facturacion_app PASSWORD 'la-nueva';" `
  -c "ALTER ROLE facturacion_operador PASSWORD 'la-nueva';"
```

Y actualiza el `.env` con las nuevas.

## Cómo funciona ahora

Al arrancar, la API y el worker buscan un `.env` subiendo desde su carpeta de
ejecución hasta encontrarlo. Se busca hacia arriba porque cada proceso corre
desde una carpeta distinta y el archivo vive en la raíz.

Las variables que ya existan en el entorno **no se sobrescriben**: así, en
producción, lo que ponga el contenedor manda sobre cualquier archivo que se
haya colado en la imagen.

Si falta una variable, el proceso **no arranca**, y el mensaje nombra cuál es
y para qué sirve. Es preferible a arrancar y fallar con la primera petición
de un cliente.

## En producción

El `.env` no se despliega. Las variables las pone el contenedor, el
orquestador o un gestor de secretos. El código es el mismo.

Y la llave maestra guárdala también en un gestor de contraseñas: si se pierde,
los certificados y las claves SOL de tus clientes quedan irrecuperables.
