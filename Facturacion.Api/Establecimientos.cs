using System.Text.RegularExpressions;
using Facturacion.Cpe;

namespace Facturacion.Api;

/// <summary>
/// 23 oct — DESDE QUÉ LOCAL SE EMITE (sucursales de la plataforma).
///
/// Es del MISMO RUC: la razón social, el RUC y el domicilio fiscal siguen
/// saliendo del tenant, nunca de la petición. Lo único que cambia es:
///
///   · `codigo` — el código de establecimiento anexo de la ficha RUC (4
///     dígitos). Va al XML en cbc:AddressTypeCode. «0000» = domicilio fiscal.
///   · `direccion` — la dirección del local, SOLO para el PDF («Local: …»).
///     No entra al XML: SUNAT ya la tiene en la ficha RUC, por el código.
///
/// Sin este bloque, todo queda como antes: 0000 y sin línea «Local».
/// </summary>
public class EstablecimientoDto
{
    public string Codigo { get; set; } = "0000";
    public string? Direccion { get; set; }
}

public static class Establecimientos
{
    private static readonly Regex CuatroRe = new("^[0-9]{4}$", RegexOptions.Compiled);
    private static Regex Cuatro() => CuatroRe;

    /// <summary>Qué tiene de malo el bloque, o null si está bien (o no vino).</summary>
    public static string? Problema(EstablecimientoDto? e)
    {
        if (e is null) return null;
        if (!Cuatro().IsMatch(e.Codigo ?? ""))
            return $"El código de establecimiento '{e.Codigo}' no es válido: son 4 dígitos, como figura en la ficha RUC (0000 = domicilio fiscal).";
        if ((e.Direccion?.Length ?? 0) > 250)
            return "La dirección del local es demasiado larga (máximo 250 caracteres).";
        return null;
    }

    /// <summary>Pone el código y la dirección del local en el emisor. Lanza ArgumentException si está mal.</summary>
    public static Emisor Aplicar(Emisor emisor, EstablecimientoDto? e)
    {
        if (e is null) return emisor;
        if (Problema(e) is { } p) throw new ArgumentException(p);

        emisor.CodigoEstablecimiento = e.Codigo;
        emisor.DireccionLocal = e.Codigo == "0000" ? "" : (e.Direccion ?? "").Trim();
        return emisor;
    }
}