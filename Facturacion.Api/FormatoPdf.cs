using Facturacion.Cpe;
using Facturacion.Pdf;
using Facturacion.Persistencia;

namespace Facturacion.Api;

/// <summary>
/// 23 OCT (039) — EL FORMATO DEL PDF DE LA EMPRESA DE LA CLAVE.
///
///   GET  /v1/configuracion/formato-pdf                 {formato}
///   PUT  /v1/configuracion/formato-pdf                 {formato: moderno | clasico}
///   GET  /v1/configuracion/formato-pdf/muestra?formato=  un PDF de ejemplo con los datos
///                                                        y el logo de la empresa
///
/// El formato vale para facturas, boletas y notas, en el panel, el portal y el
/// correo. El ticket no cambia.
/// </summary>
public static class FormatoPdf
{
    public const string Moderno = "moderno";
    public const string Clasico = "clasico";

    public static string Normalizar(string? f) =>
        string.Equals(f?.Trim(), Clasico, StringComparison.OrdinalIgnoreCase) ? Clasico : Moderno;

    public sealed record Cambio(string? Formato);

    public static void Mapear(RouteGroupBuilder grupo)
    {
        grupo.MapGet("/formato-pdf", async (ContextoEmisor emisor, RepositorioAdmin admin, CancellationToken ct) =>
            Results.Ok(new { formato = await admin.ObtenerFormatoPdfAsync(emisor.Exigir().Id, ct) ?? Moderno }))
            .WithSummary("El formato del PDF de la empresa de la clave (moderno o clasico)");

        grupo.MapPut("/formato-pdf", async (Cambio c, ContextoEmisor emisor, RepositorioAdmin admin, CancellationToken ct) =>
        {
            var pedido = c.Formato?.Trim().ToLowerInvariant();
            if (pedido is not (Moderno or Clasico))
                return Results.BadRequest(new RespuestaError("Formato inválido.", "Es «moderno» o «clasico»."));

            return await admin.GuardarFormatoPdfAsync(emisor.Exigir().Id, pedido, ct)
                ? Results.Ok(new
                  {
                      formato = pedido,
                      mensaje = pedido == Clasico
                          ? "Formato clásico (estilo SUNAT) guardado. Así salen desde ahora los PDF, también los ya emitidos."
                          : "Formato moderno guardado. Así salen desde ahora los PDF, también los ya emitidos."
                  })
                : Results.NotFound(new RespuestaError("No se encontró la empresa."));
        })
        .WithSummary("Cambia el formato del PDF de la empresa de la clave");

        grupo.MapGet("/formato-pdf/muestra", async (
            string? formato, ContextoEmisor emisor, RepositorioAdmin admin,
            IAlmacenArchivos archivos, CancellationToken ct) =>
        {
            var t = emisor.Exigir();
            var cual = Normalizar(formato);

            byte[]? logo = null;
            if ((await admin.ObtenerLogoAsync(t.Id, ct))?.LogoRuta is { Length: > 0 } ruta)
            {
                try { logo = await archivos.LeerAsync(ruta, ct); }
                catch (Exception) when (!ct.IsCancellationRequested) { /* sin logo */ }
            }

            var factura = Ejemplo(t);
            var opciones = new OpcionesImpresion(
                EstadoSunat: "EJEMPLO — sin valor ante SUNAT",
                Logo: logo,
                Extra: new Dictionary<string, string> { ["ordenCompra"] = "OC-000123" },
                Estilo: cual);

            byte[] pdf;
            try { pdf = Generar(factura, opciones); }
            catch (Exception) when (logo is not null) { pdf = Generar(factura, opciones with { Logo = null }); }

            return Results.File(pdf, "application/pdf", $"ejemplo-{cual}.pdf");
        })
        .WithSummary("Un PDF de ejemplo en el formato pedido, con los datos y el logo de la empresa");
    }

    private static byte[] Generar(ComprobanteBase c, OpcionesImpresion o) =>
        o.Estilo == Clasico ? GeneradorPdfClasico.Generar(c, "EjemploDeValorResumen=", o) : GeneradorPdf.Generar(c, "EjemploDeValorResumen=", o);

    /// <summary>Una factura de ejemplo: la empresa de verdad, un cliente y dos líneas inventadas, con detracción.</summary>
    private static Factura Ejemplo(TenantResuelto t)
    {
        var f = new Factura
        {
            Serie = "F001",
            Correlativo = 123,
            FechaEmision = RelojPeru.Ahora,
            Moneda = "PEN",
            Emisor = new Emisor
            {
                Ruc = t.Ruc, RazonSocial = t.RazonSocial, NombreComercial = t.NombreComercial, Ubigeo = t.Ubigeo,
                Direccion = t.Direccion, Distrito = t.Distrito, Provincia = t.Provincia, Departamento = t.Departamento
            },
            Receptor = new Receptor
            {
                TipoDocumento = TipoDocIdentidad.Ruc,
                NumeroDocumento = "20100070970",
                RazonSocial = "CLIENTE DE EJEMPLO S.A.C.",
                Direccion = "AV. EJEMPLO 123 - SAN ISIDRO - LIMA - LIMA"
            },
            Lineas =
            [
                new LineaComprobante { Numero = 1, CodigoProducto = "P-001", Descripcion = "Producto de ejemplo", UnidadMedida = "NIU", Cantidad = 2, ValorUnitario = 500m },
                new LineaComprobante { Numero = 2, Descripcion = "Servicio de ejemplo", UnidadMedida = "ZZ", Cantidad = 1, ValorUnitario = 350m },
            ]
        };

        var total = CalculadoraTotales.Calcular(f).ImporteTotal;
        f.Detraccion = new Detraccion(TipoOperacionDetraccion.General, CodigoDetraccion.DemasServiciosGravados,
                                      12m, Detraccion.CalcularMonto(total, 12m), "00-000-000000", "001");
        return f;
    }
}