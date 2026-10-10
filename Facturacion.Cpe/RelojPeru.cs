namespace Facturacion.Cpe;

/// <summary>
/// La hora de Perú, corra el programa donde corra.
///
/// POR QUÉ EXISTE ESTA CLASE:
///
/// DateTime.Now devuelve la hora del reloj de la máquina. En una laptop de
/// Lima eso coincide con lo que el usuario espera. En un servidor Linux el
/// reloj está en UTC, y UTC va cinco horas por delante.
///
/// Una factura emitida a las 19:00 de Lima se fecharía al día siguiente.
/// Para SUNAT eso no es un detalle cosmético: la fecha de emisión determina
/// el periodo tributario, y un comprobante del último día del mes se iría
/// al mes siguiente sin que nadie lo note hasta el cierre.
///
/// LA DISTINCIÓN QUE HAY QUE TENER PRESENTE:
///
///   Fechas del negocio  → hora de Perú. Emisión, pago, traslado, tipo de
///                         cambio. Son fechas que alguien declara ante
///                         SUNAT y que aparecen impresas en un documento.
///
///   Marcas de tiempo    → UTC. creado_en, auditoría, logs. Son instantes,
///                         no fechas, y guardarlos en UTC es lo correcto.
///                         Esas NO se tocan.
///
/// Confundir las dos es lo que produce los errores raros: o facturas con
/// fecha equivocada, o auditorías que se desordenan al cambiar de servidor.
/// </summary>
public static class RelojPeru
{
    /// <summary>
    /// La zona se resuelve una sola vez. Buscarla en cada llamada cuesta
    /// más de lo que parece: lee del sistema operativo.
    /// </summary>
    private static readonly TimeZoneInfo Zona = ResolverZona();

    /// <summary>Fecha y hora actuales en Perú.</summary>
    public static DateTime Ahora =>
        TimeZoneInfo.ConvertTimeFromUtc(DateTime.UtcNow, Zona);

    /// <summary>La fecha de hoy en Perú, sin hora.</summary>
    public static DateTime Hoy => Ahora.Date;

    /// <summary>
    /// Convierte un instante en UTC a hora de Perú. Sirve para mostrar en
    /// pantalla o en un PDF algo que se guardó como marca de tiempo.
    /// </summary>
    public static DateTime DesdeUtc(DateTime utc) =>
        TimeZoneInfo.ConvertTimeFromUtc(
            utc.Kind == DateTimeKind.Utc
                ? utc
                : DateTime.SpecifyKind(utc, DateTimeKind.Utc),
            Zona);

    /// <summary>
    /// Nombre de la zona según el sistema. Útil para un diagnóstico que
    /// diga en qué hora cree estar el servidor.
    /// </summary>
    public static string NombreZona => Zona.Id;

    /// <summary>
    /// Busca la zona horaria de Perú probando los dos nombres que existen.
    ///
    /// POR QUÉ DOS: Linux usa los identificadores IANA ("America/Lima") y
    /// Windows los suyos propios ("SA Pacific Standard Time"). Desde .NET 6
    /// ambos suelen funcionar en los dos sistemas, pero eso depende de que
    /// la máquina tenga instalada la base de datos ICU, y hay imágenes de
    /// contenedor que la traen recortada.
    ///
    /// Si ninguno está disponible, se construye una zona fija de -5 horas.
    /// Perú no aplica horario de verano desde 1994, así que ese desfase es
    /// constante y la zona inventada da el mismo resultado que la real.
    /// </summary>
    private static TimeZoneInfo ResolverZona()
    {
        string[] nombres = ["America/Lima", "SA Pacific Standard Time"];

        foreach (var nombre in nombres)
        {
            try
            {
                return TimeZoneInfo.FindSystemTimeZoneById(nombre);
            }
            catch (TimeZoneNotFoundException) { }
            catch (InvalidTimeZoneException) { }
        }

        return TimeZoneInfo.CreateCustomTimeZone(
            id: "PET",
            baseUtcOffset: TimeSpan.FromHours(-5),
            displayName: "(UTC-05:00) Peru",
            standardDisplayName: "Hora de Peru");
    }
}
