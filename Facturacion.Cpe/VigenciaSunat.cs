namespace Facturacion.Cpe;

/// <summary>
/// DESDE CUÁNDO RIGEN LAS REGLAS NUEVAS DE SUNAT (14 de octubre de 2026).
///
/// SUNAT publicó un paquete de validaciones para el 01/08/2026 y lo postergó
/// al 01/01/2027 (Reglas de validación, hoja «Control de cambios», ajuste del
/// 24/07/2026). YA LO POSTERGÓ UNA VEZ, y puede volver a hacerlo: por eso la
/// fecha no va escrita en cada sitio que la usa, sino aquí, y el worker la
/// puede cambiar con SUNAT_REGLAS_2027_DESDE (formato yyyy-MM-dd) sin tocar
/// el código.
///
/// Lo que hoy depende de esta fecha:
///   - Resumen diario: las gratuitas se informan por clase (06, 07, 08, 09)
///     en vez de todas juntas en el 05, que SUNAT desactiva.
///   - Liquidación de compra: el código de producto SUNAT pasa a ser
///     obligatorio en cada línea (ReglasLiquidacion; antes, solo un aviso).
///
/// Detalle completo en el documento del proyecto «cambios-sunat-2027.md».
///
/// LAS GRATUITAS DEL RESUMEN DIARIO, POR AMBIENTE (7 de noviembre de 2026).
/// SUNAT beta rechaza hoy las dos formas con el error 2256: el 05 («no
/// cumple con el estándar») y el 06 («no se encuentra en el catálogo 11»).
/// Un resumen sin gratuitas sí lo acepta. Así que en beta las gratuitas no se
/// informan en el resumen (la boleta ya las lleva, aceptada); en producción
/// se sigue con la fecha (05 hasta el corte, por clase desde el corte).
/// Cambiable en el worker con SUNAT_RC_GRATUITAS_BETA y
/// SUNAT_RC_GRATUITAS_PRODUCCION: «omitir» o «fecha».
/// </summary>
public static class VigenciaSunat
{
    /// <summary>La fecha oficial, mientras SUNAT no diga otra cosa.</summary>
    public static readonly DateTime FechaOficial2027 = new(2027, 1, 1);

    /// <summary>Desde cuándo se generan los documentos con las reglas de 2027.</summary>
    public static DateTime Reglas2027Desde { get; set; } = FechaOficial2027;

    /// <summary>¿Un documento generado en esta fecha va con las reglas de 2027?</summary>
    public static bool Rigen2027(DateTime fechaGeneracion) =>
        fechaGeneracion.Date >= Reglas2027Desde.Date;

    /// <summary>Gratuitas del resumen diario cuando va a SUNAT beta.</summary>
    public static GratuitasResumen GratuitasBeta { get; set; } = GratuitasResumen.NoInformar;

    /// <summary>Gratuitas del resumen diario cuando va a SUNAT producción.</summary>
    public static GratuitasResumen GratuitasProduccion { get; set; } = GratuitasResumen.SegunFecha;

    /// <summary>Cómo van las gratuitas en un resumen de este ambiente ("beta" o "produccion").</summary>
    public static GratuitasResumen GratuitasPara(string? ambiente) =>
        ambiente == "produccion" ? GratuitasProduccion : GratuitasBeta;

    /// <summary>Lee «omitir» o «fecha» (lo que se pone en el .env).</summary>
    public static bool LeerGratuitas(string? texto, out GratuitasResumen valor)
    {
        switch (texto?.Trim().ToLowerInvariant())
        {
            case "omitir": valor = GratuitasResumen.NoInformar; return true;
            case "fecha": valor = GratuitasResumen.SegunFecha; return true;
            default: valor = default; return false;
        }
    }

    private static string Texto(GratuitasResumen g) =>
        g == GratuitasResumen.NoInformar ? "no se informan" : "según la fecha (05 / por clase)";

    /// <summary>Lo que se dice al arrancar, para que nadie tenga que adivinarlo.</summary>
    public static string Diagnostico() =>
        (Reglas2027Desde.Date == FechaOficial2027
            ? "Reglas SUNAT 2027: rigen desde el 2027-01-01 (fecha oficial)."
            : $"Reglas SUNAT 2027: rigen desde el {Reglas2027Desde:yyyy-MM-dd} " +
              "(cambiada con SUNAT_REGLAS_2027_DESDE; la oficial es 2027-01-01).") +
        $" Gratuitas del resumen diario: en beta {Texto(GratuitasBeta)}; " +
        $"en producción {Texto(GratuitasProduccion)}.";
}

/// <summary>Cómo se informan las gratuitas en el resumen diario.</summary>
public enum GratuitasResumen
{
    /// <summary>Hasta la fecha de corte, todas juntas en el 05; desde el corte, por clase (06–09).</summary>
    SegunFecha,

    /// <summary>No se declaran (ni el importe del catálogo 11 ni el tributo 9996).</summary>
    NoInformar
}