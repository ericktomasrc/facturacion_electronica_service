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

    /// <summary>Lo que se dice al arrancar, para que nadie tenga que adivinarlo.</summary>
    public static string Diagnostico() =>
        Reglas2027Desde.Date == FechaOficial2027
            ? "Reglas SUNAT 2027: rigen desde el 2027-01-01 (fecha oficial)."
            : $"Reglas SUNAT 2027: rigen desde el {Reglas2027Desde:yyyy-MM-dd} " +
              "(cambiada con SUNAT_REGLAS_2027_DESDE; la oficial es 2027-01-01).";
}