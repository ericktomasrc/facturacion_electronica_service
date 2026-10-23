using System.Globalization;
using Facturacion.Cpe;
using QuestPDF.Fluent;
using QuestPDF.Helpers;
using QuestPDF.Infrastructure;

namespace Facturacion.Pdf;

/// <summary>
/// 22 OCT — LA REPRESENTACIÓN IMPRESA EN TICKET (impresora térmica de 80 o 58 mm).
///
/// Los mismos datos que el A4 —SUNAT pide los mismos en cualquier formato—,
/// en una sola columna y una hoja CONTINUA: el alto lo da el contenido, como
/// el rollo de papel. Lo que en el A4 va en tabla aquí va en dos renglones por
/// producto: «2 x CEMENTO SOL 42.5 KG» y debajo «@ 28.00 … 56.00».
///
/// Los importes por línea van CON IGV (es lo que el cliente pagó por cada
/// cosa) y el desglose (gravado, IGV) al final, como en el A4. El total, la
/// leyenda en letras, las cuotas, la detracción, el QR y el hash, igual.
///
/// 58 mm es el rollo de las impresoras portátiles: letra más chica y el QR
/// más pequeño. Debajo de 28 caracteres por renglón ya no se lee.
/// </summary>
public static class GeneradorTicket
{
    private static readonly CultureInfo Inv = CultureInfo.InvariantCulture;

    /// <summary>`ancho` en milímetros: 80 o 58.</summary>
    public static byte[] Generar(ComprobanteBase c, string? digestFirma, OpcionesImpresion? opciones, int ancho)
    {
        GeneradorPdf.ConfigurarLicencia();
        opciones ??= OpcionesImpresion.PorDefecto;

        var angosto = ancho < 70;
        var letra = angosto ? 7f : 8.5f;
        var margen = angosto ? 2.5f : 4f;

        var totales = CalculadoraTotales.Calcular(c);
        var lineas = CalculadoraTotales.CalcularLineas(c);
        var qr = CodigoQr.GenerarPng(CodigoQr.Contenido(c, totales, digestFirma));
        var simbolo = GeneradorPdf.SimboloMoneda(c.Moneda);

        var documento = Document.Create(contenedor =>
        {
            contenedor.Page(pagina =>
            {
                pagina.ContinuousSize(ancho, Unit.Millimetre);
                pagina.Margin(margen, Unit.Millimetre);
                pagina.DefaultTextStyle(x => x.FontSize(letra).LineHeight(1.15f));

                pagina.Content().Column(col =>
                {
                    col.Spacing(3);

                    // --- El emisor -----------------------------------------------
                    if (opciones.Logo is not null)
                        col.Item().AlignCenter().Height(angosto ? 28 : 38).Image(opciones.Logo).FitHeight();

                    col.Item().AlignCenter().Text(
                        string.IsNullOrWhiteSpace(c.Emisor.NombreComercial) ? c.Emisor.RazonSocial : c.Emisor.NombreComercial)
                        .Bold().FontSize(letra + 1.5f);
                    if (!string.IsNullOrWhiteSpace(c.Emisor.NombreComercial))
                        col.Item().AlignCenter().Text(c.Emisor.RazonSocial);
                    col.Item().AlignCenter().Text($"RUC {c.Emisor.Ruc}");
                    col.Item().AlignCenter().Text(c.Emisor.Direccion).FontSize(letra - 0.5f);
                    col.Item().AlignCenter().Text($"{c.Emisor.Distrito} - {c.Emisor.Provincia} - {c.Emisor.Departamento}")
                        .FontSize(letra - 0.5f);
                    // 23 oct: emitido desde un local anexo (sucursal).
                    if (!string.IsNullOrWhiteSpace(c.Emisor.DireccionLocal))
                        col.Item().AlignCenter().Text($"Local: {c.Emisor.DireccionLocal}").FontSize(letra - 0.5f);

                    Raya(col);

                    col.Item().AlignCenter().Text(GeneradorPdf.NombreDocumento(c.TipoComprobante)).Bold();
                    col.Item().AlignCenter().Text(c.NumeroCompleto).Bold().FontSize(letra + 1);

                    Raya(col);

                    // --- El cliente --------------------------------------------
                    col.Item().Text($"Fecha: {c.FechaEmision.ToString("dd/MM/yyyy", Inv)}");
                    col.Item().Text($"Cliente: {c.Receptor.RazonSocial}");
                    if (c.Receptor.TipoDocumento != TipoDocIdentidad.SinDocumento && !string.IsNullOrWhiteSpace(c.Receptor.NumeroDocumento))
                        col.Item().Text($"{GeneradorPdf.NombreTipoDoc(c.Receptor.TipoDocumento)}: {c.Receptor.NumeroDocumento}");
                    if (!string.IsNullOrWhiteSpace(c.Receptor.Direccion))
                        col.Item().Text($"Dir.: {c.Receptor.Direccion}");
                    if (c.Moneda != "PEN")
                        col.Item().Text($"Moneda: {c.Moneda}" +
                                        (c.TipoCambio is not null ? $" · T.C. {c.TipoCambio.Tasa.ToString("F3", Inv)}" : ""));
                    if (c is Factura fp)
                        col.Item().Text($"Pago: {(ReglasCredito.EsCredito(fp.FormaPago) ? "Crédito" : "Contado")}");

                    if (c is NotaCredito nc)
                        col.Item().Text($"Modifica a: {nc.Afectado.Numero} · {GeneradorPdf.DescripcionMotivo(nc)}");
                    else if (c is NotaDebito nd)
                        col.Item().Text($"Modifica a: {nd.Afectado.Numero} · {MotivoNotaDebito.Descripcion(nd.CodigoMotivo)}");

                    if (opciones.Extra is { Count: > 0 } extra)
                        foreach (var campo in extra)
                            col.Item().Text($"{GeneradorPdf.EtiquetaExtra(campo.Key)}: {campo.Value}");

                    Raya(col);

                    // --- Los productos -----------------------------------------
                    foreach (var calculada in lineas)
                    {
                        var l = calculada.Linea;
                        var gratuita = AfectacionIgv.EsGratuita(l.TipoAfectacionIgv);
                        var importe = gratuita ? 0m : calculada.ValorVenta + calculada.Igv + calculada.Isc + calculada.Icbper;

                        col.Item().Text($"{l.Cantidad.ToString("0.##", Inv)} {l.UnidadMedida} x {l.Descripcion}");
                        col.Item().Row(fila =>
                        {
                            fila.RelativeItem().PaddingLeft(6).Text(
                                gratuita ? "  gratuito, no se cobra"
                                         : $"  @ {F2(calculada.PrecioUnitarioConIgv)}" +
                                           (calculada.Descuento > 0 ? $"  dscto. {F2(calculada.Descuento)}" : ""))
                                .FontSize(letra - 0.5f).FontColor(Colors.Grey.Darken2);
                            fila.ConstantItem(angosto ? 48 : 62).AlignRight().Text(F2(importe));
                        });
                    }

                    Raya(col);

                    // --- Los totales -------------------------------------------
                    if (totales.TotalDescuentos > 0) Linea(col, "Descuentos", simbolo, -totales.TotalDescuentos);
                    if (totales.TotalGravado > 0) Linea(col, "Op. gravada", simbolo, totales.TotalGravado);
                    if (totales.TotalExonerado > 0) Linea(col, "Op. exonerada", simbolo, totales.TotalExonerado);
                    if (totales.TotalInafecto > 0) Linea(col, "Op. inafecta", simbolo, totales.TotalInafecto);
                    if (totales.TotalExportacion > 0) Linea(col, "Op. exportación", simbolo, totales.TotalExportacion);
                    if (totales.HayIvap)
                        Linea(col, $"IVAP {Ivap.Tasa:0.##}%", simbolo, totales.TotalIvap);
                    else
                        Linea(col, "IGV 18%", simbolo, totales.TotalIgv);
                    if (totales.TotalIsc > 0) Linea(col, "ISC", simbolo, totales.TotalIsc);
                    if (totales.TotalIcbper > 0) Linea(col, "ICBPER (bolsas)", simbolo, totales.TotalIcbper);
                    if (totales.TotalOtrosCargos > 0) Linea(col, "Otros cargos", simbolo, totales.TotalOtrosCargos);
                    if (totales.TotalOtrosDescuentos > 0) Linea(col, "Otros dsctos.", simbolo, -totales.TotalOtrosDescuentos);
                    if (totales.TotalAnticipos > 0) Linea(col, "Anticipos", simbolo, -totales.TotalAnticipos);

                    col.Item().Row(fila =>
                    {
                        fila.RelativeItem().Text("TOTAL").Bold().FontSize(letra + 1.5f);
                        fila.AutoItem().AlignRight().Text($"{simbolo} {F2(totales.ImporteTotal)}").Bold().FontSize(letra + 1.5f);
                    });

                    if (totales.TotalGratuito > 0)
                        Linea(col, "Op. gratuitas (no se cobran)", simbolo, totales.TotalGratuito);

                    col.Item().Text(NumeroALetras.Leyenda(totales.ImporteTotal, c.Moneda)).FontSize(letra - 0.5f);

                    // --- Cuotas y detracción -------------------------------------
                    if (c is Factura f)
                    {
                        foreach (var cuota in f.Cuotas.OrderBy(x => x.Numero))
                            col.Item().Text($"Cuota {cuota.Numero}: {simbolo} {F2(cuota.Monto)} · vence {cuota.FechaVencimiento.ToString("dd/MM/yyyy", Inv)}")
                                .FontSize(letra - 0.5f);

                        if (f.Detraccion is { } d)
                        {
                            col.Item().Text(Detraccion.TextoLeyenda).FontSize(letra - 1f);
                            col.Item().Text($"Detracción {d.CodigoBienServicio} · {d.Porcentaje.ToString("0.##", Inv)}% · S/ {F2(d.Monto)}")
                                .FontSize(letra - 0.5f);
                            col.Item().Text($"Cta. Banco de la Nación {d.CuentaBancoNacion}").FontSize(letra - 0.5f);
                        }

                        if (f.Percepcion is not null)
                            col.Item().Text($"Percepción {f.Percepcion.Porcentaje.ToString("0.##", Inv)}%: S/ {F2(f.Percepcion.Monto)} · " +
                                            $"total a pagar S/ {F2(f.Percepcion.TotalConPercepcion)}").FontSize(letra - 0.5f);
                    }

                    if (totales.TotalGratuito > 0)
                        col.Item().Text(Gratuitas.TextoLeyenda).FontSize(letra - 1f);
                    if (Ivap.Aplica(c))
                        col.Item().Text(Ivap.TextoLeyenda).FontSize(letra - 1f);

                    Raya(col);

                    // --- QR, hash y la frase de SUNAT -----------------------------
                    var lado = angosto ? 26f : 32f;
                    col.Item().AlignCenter().Width(lado, Unit.Millimetre).Height(lado, Unit.Millimetre).Image(qr).FitArea();

                    col.Item().AlignCenter().Text(
                        $"Representación impresa de la {GeneradorPdf.NombreDocumento(c.TipoComprobante).ToLowerInvariant()}.")
                        .FontSize(letra - 1f);
                    if (!string.IsNullOrWhiteSpace(digestFirma))
                        col.Item().AlignCenter().Text($"Hash: {digestFirma}").FontSize(letra - 1.5f);
                    if (!string.IsNullOrWhiteSpace(opciones.EstadoSunat))
                        col.Item().AlignCenter().Text(opciones.EstadoSunat).FontSize(letra - 1f).FontColor(Colors.Grey.Darken2);
                    col.Item().AlignCenter().Text("Gracias por su compra").SemiBold();
                });
            });
        });

        return documento.GeneratePdf();
    }

    private static void Raya(ColumnDescriptor col) =>
        col.Item().PaddingVertical(1).LineHorizontal(0.6f).LineColor(Colors.Grey.Darken1);

    private static void Linea(ColumnDescriptor col, string etiqueta, string simbolo, decimal monto) =>
        col.Item().Row(fila =>
        {
            fila.RelativeItem().Text(etiqueta);
            fila.AutoItem().AlignRight().Text(monto < 0 ? $"- {simbolo} {F2(-monto)}" : $"{simbolo} {F2(monto)}");
        });

    private static string F2(decimal valor) => valor.ToString("N2", Inv);
}