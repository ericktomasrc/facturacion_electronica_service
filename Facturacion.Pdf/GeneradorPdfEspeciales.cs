using System.Globalization;
using Facturacion.Cpe;
using QuestPDF.Fluent;
using QuestPDF.Helpers;
using QuestPDF.Infrastructure;

namespace Facturacion.Pdf;

/// <summary>
/// Representación impresa de los tres documentos que no son ventas.
///
///   Liquidación de compra (04)   el comprador documenta lo que compró
///   Comprobante de retención (20) el agente constata lo que se quedó
///   Comprobante de percepción (40) el agente constata lo que cobró de más
///
/// POR QUÉ NO VAN EN GeneradorPdf: porque aquel imprime una venta, y una
/// venta tiene un detalle de productos, un IGV que el cliente paga y un total
/// que es el número más grande de la hoja. Aquí no se cumple ninguna de las
/// tres cosas:
///
///   - La liquidación tiene productos, pero su total es el MENOR de la hoja:
///     al valor se le resta el IGV y la retención de renta.
///   - La retención y la percepción no tienen productos: su detalle son las
///     facturas de otro.
///
/// Forzarlos en el mismo generador habría llenado aquel archivo de "si el
/// tipo es 20 entonces no imprimas el detalle", que es exactamente lo que se
/// rompe la primera vez que alguien toca el diseño de la factura.
///
/// EL PDF NO ES EL COMPROBANTE. El comprobante es el XML firmado; esto es lo
/// que una persona lee. Si difieren, vale el XML.
/// </summary>
public static class GeneradorPdfEspeciales
{
    private static readonly CultureInfo Inv = CultureInfo.InvariantCulture;

    private static string F2(decimal valor) => valor.ToString("N2", Inv);

    private static string Fecha(DateTime f) => f.ToString("dd/MM/yyyy", Inv);

    // ================================================== liquidación de compra

    public static byte[] Generar(
        LiquidacionCompra lc, string? digestFirma, OpcionesImpresion? opciones = null)
    {
        GeneradorPdf.ConfigurarLicencia();

        opciones ??= OpcionesImpresion.PorDefecto;

        var totales = CalculadoraLiquidacion.Calcular(lc);
        var lineas = CalculadoraLiquidacion.CalcularLineas(lc);

        var qr = TextoQr(
            lc, totales.Igv, totales.ImporteAPagar,
            lc.Vendedor.TipoDocumento, lc.Vendedor.NumeroDocumento, digestFirma);

        return Pagina(
            "LIQUIDACIÓN DE COMPRA ELECTRÓNICA", lc, qr, opciones,
            columna =>
            {
                columna.Item().Element(e => VendedorYLugar(e, lc));
                columna.Item().Element(e => DetalleLiquidacion(e, lc, lineas));
                columna.Item().Element(e => TotalesLiquidacionImpresos(e, lc, totales));

                columna.Item().Text(
                    NumeroALetras.Leyenda(totales.ImporteAPagar, lc.Moneda))
                    .FontSize(8).SemiBold();

                // LA ADVERTENCIA QUE EVITA LA LLAMADA DEL VENDEDOR.
                //
                // El agricultor ve un documento por 7 080 y cobra 5 910. Sin
                // esta línea, la diferencia parece un descuento que nadie le
                // avisó.
                columna.Item().PaddingTop(4).Text(
                    "El IGV de esta operación lo asume el comprador como crédito " +
                    "fiscal. La retención de renta se deposita a SUNAT a cuenta " +
                    "del impuesto del vendedor.")
                    .FontSize(7.5f).FontColor(Colors.Grey.Darken2);
            });
    }

    // ================================================ retención y percepción

    public static byte[] Generar(
        ComprobanteRetencion r, string? digestFirma, OpcionesImpresion? opciones = null)
    {
        GeneradorPdf.ConfigurarLicencia();

        var totales = CalculadoraCre.Calcular(r);

        return GenerarCre(
            r, r.Proveedor, totales, r.Tasa, r.Observaciones, digestFirma, opciones,
            titulo: "COMPROBANTE DE RETENCIÓN ELECTRÓNICO",
            etiquetaContraparte: "PROVEEDOR",
            etiquetaTotal: "Importe total retenido",
            etiquetaNeto: "Importe total pagado",
            etiquetaColumnaMonto: "Retenido",
            etiquetaColumnaNeto: "Neto pagado",
            nota:
                "El importe retenido se deposita a SUNAT a cuenta del IGV del " +
                "proveedor. No es un descuento: es un pago adelantado de su " +
                "impuesto, y este documento es la constancia para deducirlo.");
    }

    public static byte[] Generar(
        ComprobantePercepcion p, string? digestFirma, OpcionesImpresion? opciones = null)
    {
        GeneradorPdf.ConfigurarLicencia();

        var totales = CalculadoraCre.Calcular(p);

        return GenerarCre(
            p, p.Cliente, totales, p.Tasa, p.Observaciones, digestFirma, opciones,
            titulo: "COMPROBANTE DE PERCEPCIÓN ELECTRÓNICO",
            etiquetaContraparte: "CLIENTE",
            etiquetaTotal: "Importe total percibido",
            etiquetaNeto: "Importe total cobrado",
            etiquetaColumnaMonto: "Percibido",
            etiquetaColumnaNeto: "Neto cobrado",
            nota:
                "El importe percibido se deposita a SUNAT a cuenta del IGV del " +
                "cliente. Este documento es la constancia para deducirlo.");
    }

    private static byte[] GenerarCre(
        ComprobanteBase c,
        ContraparteCre contraparte,
        TotalesCre totales,
        decimal tasa,
        string observaciones,
        string? digestFirma,
        OpcionesImpresion? opciones,
        string titulo,
        string etiquetaContraparte,
        string etiquetaTotal,
        string etiquetaNeto,
        string etiquetaColumnaMonto,
        string etiquetaColumnaNeto,
        string nota)
    {
        opciones ??= OpcionesImpresion.PorDefecto;

        // EL QR DECLARA CERO DE IGV, y no es un olvido: estos documentos no
        // tienen IGV propio. Lo que declaran es cuánto se retuvo o percibió
        // del IGV de OTRA operación.
        var qr = TextoQr(
            c, 0m, totales.Total,
            TipoDocIdentidad.Ruc, contraparte.Ruc, digestFirma);

        return Pagina(titulo, c, qr, opciones, columna =>
        {
            columna.Item().Element(e =>
                Contraparte(e, etiquetaContraparte, contraparte, tasa));

            columna.Item().Element(e =>
                DetalleCre(e, totales, etiquetaColumnaMonto, etiquetaColumnaNeto));

            columna.Item().Element(e =>
                TotalesCreImpresos(e, totales, etiquetaTotal, etiquetaNeto));

            columna.Item().Text(NumeroALetras.Leyenda(totales.Total, "PEN"))
                .FontSize(8).SemiBold();

            if (!string.IsNullOrWhiteSpace(observaciones))
            {
                columna.Item().PaddingTop(4).Text($"Observaciones: {observaciones}")
                    .FontSize(8);
            }

            columna.Item().PaddingTop(4).Text(nota)
                .FontSize(7.5f).FontColor(Colors.Grey.Darken2);
        });
    }

    // ============================================================ el armazón

    /// <summary>
    /// La hoja: cabecera con el emisor y el recuadro del número, el contenido
    /// que le pase cada documento, y el pie con el QR.
    ///
    /// Es lo único que los tres comparten de verdad, y por eso es lo único
    /// que está compartido.
    /// </summary>
    private static byte[] Pagina(
        string titulo,
        ComprobanteBase c,
        string textoQr,
        OpcionesImpresion opciones,
        Action<ColumnDescriptor> contenido)
    {
        var imagenQr = CodigoQr.GenerarPng(textoQr);

        var documento = Document.Create(contenedor =>
        {
            contenedor.Page(pagina =>
            {
                pagina.Size(PageSizes.A4);
                pagina.Margin(1.5f, Unit.Centimetre);
                pagina.DefaultTextStyle(x => x.FontSize(9));

                pagina.Header().Element(e => Encabezado(e, c, titulo, opciones));

                pagina.Content().PaddingVertical(12).Column(columna =>
                {
                    columna.Spacing(10);
                    contenido(columna);
                });

                pagina.Footer().Element(e => PiePagina(e, imagenQr, opciones));
            });
        });

        return documento.GeneratePdf();
    }

    private static void Encabezado(
        IContainer contenedor, ComprobanteBase c, string titulo,
        OpcionesImpresion opciones)
    {
        contenedor.Row(fila =>
        {
            fila.RelativeItem().Column(columna =>
            {
                if (opciones.Logo is not null)
                    columna.Item().Height(50).Image(opciones.Logo).FitHeight();

                columna.Item().Text(
                    string.IsNullOrWhiteSpace(c.Emisor.NombreComercial)
                        ? c.Emisor.RazonSocial
                        : c.Emisor.NombreComercial)
                    .FontSize(14).Bold();

                columna.Item().Text(c.Emisor.RazonSocial).FontSize(8);
                columna.Item().Text(c.Emisor.Direccion).FontSize(8);

                columna.Item().Text(
                    $"{c.Emisor.Distrito} - {c.Emisor.Provincia} - {c.Emisor.Departamento}")
                    .FontSize(8);
            });

            fila.ConstantItem(20);

            fila.ConstantItem(200)
                .Border(1).BorderColor(Colors.Grey.Darken1)
                .Padding(8)
                .Column(columna =>
                {
                    columna.Spacing(3);

                    columna.Item().AlignCenter()
                        .Text($"R.U.C. {c.Emisor.Ruc}")
                        .FontSize(11).Bold();

                    columna.Item().AlignCenter().Text(titulo)
                        .FontSize(9.5f).Bold();

                    columna.Item().AlignCenter().Text(c.NumeroCompleto)
                        .FontSize(12).Bold();

                    columna.Item().AlignCenter()
                        .Text($"Emitido el {Fecha(c.FechaEmision)}")
                        .FontSize(8);
                });
        });
    }

    private static void PiePagina(
        IContainer contenedor, byte[] qr, OpcionesImpresion opciones)
    {
        contenedor.PaddingTop(8).BorderTop(0.5f)
            .BorderColor(Colors.Grey.Lighten1).PaddingTop(8)
            .Row(fila =>
            {
                fila.ConstantItem(78).Height(78).Image(qr).FitArea();

                fila.ConstantItem(12);

                fila.RelativeItem().PaddingTop(4).Column(columna =>
                {
                    columna.Spacing(2);

                    columna.Item().Text(
                        "Representación impresa del comprobante electrónico.")
                        .FontSize(7.5f);

                    columna.Item().Text(
                        "Puede verificarlo en el portal de SUNAT usando el código QR.")
                        .FontSize(7.5f).FontColor(Colors.Grey.Darken1);

                    if (!string.IsNullOrWhiteSpace(opciones.EstadoSunat))
                    {
                        columna.Item().PaddingTop(3).Text(t =>
                        {
                            t.Span("Estado: ").FontSize(7.5f).SemiBold();
                            t.Span(opciones.EstadoSunat).FontSize(7.5f);

                            if (!string.IsNullOrWhiteSpace(opciones.MensajeSunat))
                                t.Span($"  ({opciones.MensajeSunat})").FontSize(7);
                        });
                    }
                });
            });
    }

    // ================================================== bloques: liquidación

    /// <summary>
    /// El vendedor y el lugar de la compra, que son dos datos distintos y hay
    /// que enseñarlos por separado: el vendedor vive en un sitio y la chacra
    /// está en otro.
    /// </summary>
    private static void VendedorYLugar(IContainer contenedor, LiquidacionCompra lc)
    {
        contenedor.Background(Colors.Grey.Lighten4).Padding(8).Column(columna =>
        {
            columna.Spacing(3);

            columna.Item().Row(fila =>
            {
                fila.RelativeItem().Text(t =>
                {
                    t.Span("VENDEDOR: ").SemiBold();
                    t.Span(lc.Vendedor.Nombres);
                });

                fila.ConstantItem(190).Text(t =>
                {
                    t.Span($"{NombreDocumento(lc.Vendedor.TipoDocumento)}: ").SemiBold();
                    t.Span(lc.Vendedor.NumeroDocumento);
                });
            });

            columna.Item().Text(t =>
            {
                t.Span("Domicilio: ").SemiBold();
                t.Span($"{lc.Vendedor.Direccion} — {lc.Vendedor.Distrito}, " +
                       $"{lc.Vendedor.Provincia}, {lc.Vendedor.Departamento}");
            });

            columna.Item().Text(t =>
            {
                t.Span("Lugar de la operación: ").SemiBold();
                t.Span($"{lc.Lugar.Direccion} — {lc.Lugar.Distrito}, " +
                       $"{lc.Lugar.Provincia} " +
                       $"({TipoDireccion.Descripcion(lc.Lugar.Condicion)})");
            });

            columna.Item().Text(t =>
            {
                t.Span("Tipo de operación: ").SemiBold();
                t.Span(TipoOperacionLc.Descripcion(lc.TipoOperacion));
            });
        });
    }

    private static void DetalleLiquidacion(
        IContainer contenedor, LiquidacionCompra lc, IReadOnlyList<LineaLiquidacion> lineas)
    {
        contenedor.Table(tabla =>
        {
            tabla.ColumnsDefinition(columnas =>
            {
                columnas.ConstantColumn(28);
                columnas.ConstantColumn(54);
                columnas.ConstantColumn(38);
                columnas.RelativeColumn();
                columnas.ConstantColumn(66);
                columnas.ConstantColumn(72);
            });

            tabla.Header(cabecera =>
            {
                Titulo(cabecera, "#");
                Titulo(cabecera, "Cant.");
                Titulo(cabecera, "Und.");
                Titulo(cabecera, "Descripción");
                Titulo(cabecera, "V. Unit.", derecha: true);
                Titulo(cabecera, "Importe", derecha: true);
            });

            foreach (var c in lineas)
            {
                Celda(tabla, c.Numero.ToString(Inv));
                Celda(tabla, c.Origen.Cantidad.ToString("0.##", Inv));
                Celda(tabla, c.Origen.UnidadMedida);
                Celda(tabla, c.Origen.Descripcion);
                Celda(tabla, F2(c.Origen.ValorUnitario), derecha: true);
                Celda(tabla, F2(c.ValorVenta), derecha: true);
            }
        });
    }

    /// <summary>
    /// Los totales de la liquidación.
    ///
    /// AQUÍ ESTÁ LO QUE HAY QUE ENSEÑAR BIEN O EL VENDEDOR LLAMA: las dos
    /// restas. Si solo se imprimiera el valor y el total a pagar, la
    /// diferencia parecería un recorte arbitrario.
    /// </summary>
    private static void TotalesLiquidacionImpresos(
        IContainer contenedor, LiquidacionCompra lc, TotalesLiquidacion t)
    {
        contenedor.Row(fila =>
        {
            fila.RelativeItem();

            fila.ConstantItem(250).Column(columna =>
            {
                var simbolo = Simbolo(lc.Moneda);

                if (t.HayGravadas)
                    Renglon(columna, "Valor de compra gravado", simbolo, t.ValorVentaGravado);

                if (t.HayExoneradas)
                    Renglon(columna, "Valor de compra exonerado", simbolo, t.ValorVentaExonerado);

                if (t.HayInafectas)
                    Renglon(columna, "Valor de compra inafecto", simbolo, t.ValorVentaInafecto);

                if (t.HayGratuitas)
                    Renglon(columna, "Transferencias gratuitas", simbolo, t.ValorVentaGratuito);

                Renglon(columna, "IGV", simbolo, t.Igv);

                Renglon(columna, "Subtotal", simbolo, t.Subtotal, fuerte: true);

                // Las dos restas, con signo, para que la cuenta se siga con
                // el dedo.
                Renglon(columna, "IGV que asume el comprador", simbolo, -t.Igv);

                if (t.Retencion > 0)
                {
                    Renglon(columna,
                        $"Retención de renta ({lc.TasaRetencionRenta.ToString("0.##", Inv)}%)",
                        simbolo, -t.Retencion);
                }

                columna.Item().PaddingTop(4).BorderTop(1)
                    .BorderColor(Colors.Grey.Darken1).PaddingTop(4)
                    .Row(f =>
                    {
                        f.RelativeItem().Text("IMPORTE A PAGAR AL VENDEDOR")
                            .SemiBold().FontSize(10);

                        f.ConstantItem(90).AlignRight()
                            .Text($"{simbolo} {F2(t.ImporteAPagar)}")
                            .Bold().FontSize(11);
                    });
            });
        });
    }

    // ====================================== bloques: retención y percepción

    private static void Contraparte(
        IContainer contenedor, string etiqueta, ContraparteCre c, decimal tasa)
    {
        contenedor.Background(Colors.Grey.Lighten4).Padding(8).Column(columna =>
        {
            columna.Spacing(3);

            columna.Item().Row(fila =>
            {
                fila.RelativeItem().Text(t =>
                {
                    t.Span($"{etiqueta}: ").SemiBold();
                    t.Span(c.RazonSocial);
                });

                fila.ConstantItem(190).Text(t =>
                {
                    t.Span("RUC: ").SemiBold();
                    t.Span(c.Ruc);
                });
            });

            if (!string.IsNullOrWhiteSpace(c.Direccion))
            {
                columna.Item().Text(t =>
                {
                    t.Span("Domicilio: ").SemiBold();
                    t.Span(c.Direccion);
                });
            }

            columna.Item().Text(t =>
            {
                t.Span("Tasa aplicada: ").SemiBold();
                t.Span($"{tasa.ToString("0.##", Inv)}%");
            });
        });
    }

    /// <summary>
    /// El detalle: las facturas sobre las que se retuvo o percibió.
    ///
    /// SON TRES IMPORTES POR FILA Y CADA UNO DICE OTRA COSA. El de la factura,
    /// el del pago —que puede ser una parte— y el retenido. Juntarlos en dos
    /// columnas era lo cómodo y deja al lector sin saber por qué el porcentaje
    /// no cuadra cuando se paga a plazos.
    /// </summary>
    private static void DetalleCre(
        IContainer contenedor, TotalesCre totales,
        string etiquetaMonto, string etiquetaNeto)
    {
        contenedor.Table(tabla =>
        {
            tabla.ColumnsDefinition(columnas =>
            {
                columnas.ConstantColumn(28);
                columnas.RelativeColumn();
                columnas.ConstantColumn(60);
                columnas.ConstantColumn(66);
                columnas.ConstantColumn(66);
                columnas.ConstantColumn(66);
            });

            tabla.Header(cabecera =>
            {
                Titulo(cabecera, "#");
                Titulo(cabecera, "Documento");
                Titulo(cabecera, "F. pago");
                Titulo(cabecera, "Pago", derecha: true);
                Titulo(cabecera, etiquetaMonto, derecha: true);
                Titulo(cabecera, etiquetaNeto, derecha: true);
            });

            var numero = 1;

            foreach (var linea in totales.Lineas)
            {
                var d = linea.Documento;

                Celda(tabla, (numero++).ToString(Inv));

                tabla.Cell().BorderBottom(0.5f).BorderColor(Colors.Grey.Lighten2)
                    .PaddingVertical(4).PaddingHorizontal(3).Column(col =>
                    {
                        col.Item().Text(d.Numero);

                        col.Item().Text(
                            $"Emitida el {Fecha(d.FechaEmision)} · " +
                            $"Total {d.Moneda} {F2(d.ImporteTotal)}")
                            .FontSize(7).FontColor(Colors.Grey.Darken1);

                        // Cuando la factura no está en soles, se enseña la
                        // conversión: es la única forma de que los importes
                        // en soles de la derecha se entiendan.
                        if (d.EsMonedaExtranjera && d.TipoCambio is not null)
                        {
                            col.Item().Text(
                                $"T.C. {d.TipoCambio.Tasa.ToString("0.000", Inv)} " +
                                $"→ S/ {F2(linea.ImporteEnSoles)}")
                                .FontSize(7).FontColor(Colors.Grey.Darken1);
                        }

                        if (d.NumeroPago > 1)
                        {
                            col.Item().Text($"Pago n.º {d.NumeroPago}")
                                .FontSize(7).FontColor(Colors.Grey.Darken1);
                        }
                    });

                Celda(tabla, Fecha(d.FechaPago));
                Celda(tabla, $"{d.Moneda} {F2(d.ImportePago)}", derecha: true);
                Celda(tabla, $"S/ {F2(linea.Monto)}", derecha: true);
                Celda(tabla, $"S/ {F2(linea.Neto)}", derecha: true);
            }
        });
    }

    private static void TotalesCreImpresos(
        IContainer contenedor, TotalesCre t, string etiquetaTotal, string etiquetaNeto)
    {
        contenedor.Row(fila =>
        {
            fila.RelativeItem();

            fila.ConstantItem(250).Column(columna =>
            {
                Renglon(columna, etiquetaNeto, "S/", t.Neto);

                columna.Item().PaddingTop(4).BorderTop(1)
                    .BorderColor(Colors.Grey.Darken1).PaddingTop(4)
                    .Row(f =>
                    {
                        f.RelativeItem().Text(etiquetaTotal.ToUpperInvariant())
                            .SemiBold().FontSize(10);

                        f.ConstantItem(90).AlignRight()
                            .Text($"S/ {F2(t.Total)}")
                            .Bold().FontSize(11);
                    });
            });
        });
    }

    // ============================================================ auxiliares

    private static void Renglon(
        ColumnDescriptor columna, string etiqueta, string simbolo, decimal valor,
        bool fuerte = false)
    {
        columna.Item().Row(fila =>
        {
            var izquierda = fila.RelativeItem().Text(etiqueta).FontSize(9);

            if (fuerte) izquierda.SemiBold();

            var derecha = fila.ConstantItem(90).AlignRight()
                .Text($"{simbolo} {F2(valor)}").FontSize(9);

            if (fuerte) derecha.SemiBold();
        });
    }

    private static void Titulo(
        TableCellDescriptor t, string texto, bool derecha = false)
    {
        var celda = t.Cell()
            .Background(Colors.Grey.Lighten2)
            .PaddingVertical(5).PaddingHorizontal(3);

        (derecha ? celda.AlignRight() : celda).Text(texto).SemiBold().FontSize(8);
    }

    private static void Celda(
        TableDescriptor t, string texto, bool derecha = false)
    {
        var celda = t.Cell()
            .BorderBottom(0.5f).BorderColor(Colors.Grey.Lighten2)
            .PaddingVertical(4).PaddingHorizontal(3);

        (derecha ? celda.AlignRight() : celda).Text(texto);
    }

    private static string Simbolo(string moneda) => moneda switch
    {
        "PEN" => "S/",
        "USD" => "US$",
        "EUR" => "€",
        _     => moneda
    };

    private static string NombreDocumento(string tipo) => tipo switch
    {
        TipoDocIdentidad.Ruc         => "RUC",
        TipoDocIdentidad.Dni         => "DNI",
        TipoDocIdentidad.Pasaporte   => "Pasaporte",
        TipoDocIdentidad.Extranjeria => "C. Extranjería",
        _                            => "Documento"
    };

    /// <summary>
    /// El contenido del QR, con el mismo formato que el de una factura.
    ///
    /// Se arma aquí y no con CodigoQr.Contenido porque aquel saca el IGV y el
    /// total de TotalesComprobante, que es la estructura de una venta. Estos
    /// documentos tienen sus propios totales y su propia contraparte.
    /// </summary>
    private static string TextoQr(
        ComprobanteBase c,
        decimal igv,
        decimal total,
        string tipoDocContraparte,
        string numDocContraparte,
        string? digestFirma)
    {
        var campos = new[]
        {
            c.Emisor.Ruc,
            c.TipoComprobante,
            c.Serie,
            c.Correlativo.ToString(Inv),
            igv.ToString("F2", Inv),
            total.ToString("F2", Inv),
            c.FechaEmision.ToString("yyyy-MM-dd", Inv),
            tipoDocContraparte,
            numDocContraparte,
            digestFirma ?? ""
        };

        // Termina en barra: forma parte del formato.
        return string.Join("|", campos) + "|";
    }
}
