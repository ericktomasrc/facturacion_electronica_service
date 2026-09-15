namespace Facturacion.Persistencia;

/// <summary>
/// Lee los secretos del entorno, no de archivos versionados.
///
/// NO CONFUNDIR con IProtectorDeSecretos, que está en Secretos.cs: aquel
/// CIFRA datos de los clientes —certificados y claves SOL—, y este LEE la
/// configuración del propio servicio. Dos cosas distintas que la palabra
/// "secretos" agrupa sin querer.
///
/// POR QUÉ NO VAN EN appsettings.json:
///
/// Ese archivo se versiona. Una contraseña escrita ahí queda en el historial
/// de Git para siempre, visible para cualquiera con acceso al repositorio,
/// incluso después de borrarla del archivo actual. Y los repositorios se
/// clonan, se comparten y a veces se hacen públicos por error.
///
/// La regla: si el valor da acceso a algo, no va en el repositorio.
///
/// En desarrollo se leen de un archivo .env que está en el .gitignore. En
/// producción vienen del entorno del contenedor o de un gestor de secretos,
/// y este código no cambia.
/// </summary>
public static class ConfiguracionSecretos
{
    /// <summary>
    /// Carga un archivo .env buscándolo hacia arriba desde el directorio de
    /// ejecución.
    ///
    /// SE BUSCA HACIA ARRIBA a propósito: la API corre desde
    /// Facturacion.Api/bin/Debug/net8.0 y el worker desde otra carpeta, pero
    /// el .env vive en la raíz de la solución. Una ruta relativa fija
    /// funcionaría para uno y fallaría para el otro.
    ///
    /// Las variables ya definidas en el entorno NO se sobrescriben: así, en
    /// producción, lo que ponga el contenedor manda sobre cualquier archivo
    /// que se haya colado en la imagen.
    /// </summary>
    public static void CargarArchivoEnv(string nombre = ".env")
    {
        var directorio = new DirectoryInfo(AppContext.BaseDirectory);

        while (directorio is not null)
        {
            var candidato = Path.Combine(directorio.FullName, nombre);

            if (File.Exists(candidato))
            {
                LeerArchivo(candidato);
                return;
            }

            directorio = directorio.Parent;
        }

        // No encontrarlo NO es un error: en producción las variables vienen
        // del entorno y no hay archivo. Si falta algo, lo dirá Exigir con un
        // mensaje que nombra la variable concreta.
    }

    private static void LeerArchivo(string ruta)
    {
        foreach (var linea in File.ReadAllLines(ruta))
        {
            var texto = linea.Trim();

            if (texto.Length == 0 || texto.StartsWith('#')) continue;

            var separador = texto.IndexOf('=');
            if (separador <= 0) continue;

            var nombre = texto[..separador].Trim();
            var valor = texto[(separador + 1)..].Trim();

            // Se admiten comillas por comodidad, pero no forman parte del valor.
            if (valor.Length >= 2 &&
                ((valor[0] == '"' && valor[^1] == '"') ||
                 (valor[0] == '\'' && valor[^1] == '\'')))
            {
                valor = valor[1..^1];
            }

            // Lo que ya está en el entorno tiene prioridad.
            if (Environment.GetEnvironmentVariable(nombre) is null)
                Environment.SetEnvironmentVariable(nombre, valor);
        }
    }

    /// <summary>
    /// Devuelve el valor de una variable, o detiene el arranque si falta.
    ///
    /// FALLA AL ARRANCAR, NO AL PRIMER USO. Descubrir que falta la clave de
    /// la base de datos cuando llega la primera petición es peor que
    /// descubrirlo al encender el servicio: el proceso ya está en marcha, el
    /// balanceador le manda tráfico, y los errores aparecen del lado del
    /// cliente.
    /// </summary>
    public static string Exigir(string nombre, string? paraQue = null)
    {
        var valor = Environment.GetEnvironmentVariable(nombre);

        if (!string.IsNullOrWhiteSpace(valor)) return valor;

        var explicacion = paraQue is null ? "" : $" Se usa para: {paraQue}.";

        throw new InvalidOperationException(
            $"Falta la variable de entorno {nombre}.{explicacion} " +
            "Copia .env.ejemplo como .env en la raíz de la solución y " +
            "rellena los valores.");
    }

    /// <summary>Valor opcional, con uno por defecto para desarrollo.</summary>
    public static string Opcional(string nombre, string porDefecto) =>
        Environment.GetEnvironmentVariable(nombre) is { Length: > 0 } valor
            ? valor
            : porDefecto;

    /// <summary>
    /// Arma la cadena de conexión a partir de piezas sueltas.
    ///
    /// Se compone aquí en vez de guardarla entera porque solo la contraseña
    /// es secreta: el servidor, el puerto y el nombre de la base son
    /// configuración normal y conviene poder verlos en appsettings.json.
    /// </summary>
    public static string CadenaPostgres(
        string usuario, string variableClave, string paraQue)
    {
        var servidor = Opcional("POSTGRES_HOST", "localhost");
        var puerto = Opcional("POSTGRES_PORT", "5433");
        var base_ = Opcional("POSTGRES_DB", "facturacion");
        var clave = Exigir(variableClave, paraQue);

        return $"Host={servidor};Port={puerto};Database={base_};" +
               $"Username={usuario};Password={clave}";
    }
}
