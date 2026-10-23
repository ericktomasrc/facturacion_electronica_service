using System.Globalization;
using Facturacion.Cpe;
using QuestPDF.Fluent;
using QuestPDF.Helpers;
using QuestPDF.Infrastructure;

namespace Facturacion.Pdf;

/// <summary>
/// 23 OCT — EL FORMATO «CLÁSICO SUNAT» de la representación impresa (A4).
///
/// Pedido por clientes acostumbrados al PDF del portal de SUNAT (SEE-SOL):
/// blanco y negro, recuadro del RUC a la derecha, datos del cliente en
/// columna, tabla con bordes, cuadro de totales con TODAS las filas aunque
/// estén en cero, «SON: …» y el cuadro de la detracción.
///
/// LO QUE NO SE COPIA DEL PORTAL, y no es un descuido:
///   · su pie («generada en el Sistema de SUNAT»): estos comprobantes los
///     emite la empresa desde su sistema, no SUNAT;
///   · la falta de QR: a quien emite desde su sistema, SUNAT le exige el QR
///     (o el valor resumen) en la representación impresa. Van en el pie.
///
/// LOS IMPORTES SUMAN, como en el formato moderno: valor de venta + ISC + IGV
/// + ICBPER + otros cargos − otros descuentos − anticipos = importe total.
/// </summary>
public static class GeneradorPdfClasico
{
    private static readonly CultureInfo Inv = CultureInfo.InvariantCulture;
    private const float Letra = 8.5f;

    public static byte[] Generar(ComprobanteBase c, string? digestFirma, OpcionesImpresion? opciones = null)
    {
        GeneradorPdf.ConfigurarLicencia();
        opciones ??= OpcionesImpresion.PorDefecto;

        // UN COMPROBANTE NO SE QUEDA SIN PDF POR EL DISEÑO: si algo de este
        // formato no cabe (un logo muy ancho, un texto sin espacios), sale en
        // el formato moderno, que ya está probado.
        try
        {
            return Dibujar(c, digestFirma, opciones);
        }
        catch (QuestPDF.Drawing.Exceptions.DocumentLayoutException)
        {
            return GeneradorPdf.Generar(c, digestFirma, opciones);
        }
    }

    private static byte[] Dibujar(ComprobanteBase c, string? digestFirma, OpcionesImpresion opciones)
    {
        var totales = CalculadoraTotales.Calcular(c);
        var lineas = CalculadoraTotales.CalcularLineas(c);
        var qr = CodigoQr.GenerarPng(CodigoQr.Contenido(c, totales, digestFirma));

        return Document.Create(contenedor =>
        {
            contenedor.Page(pagina =>
            {
                pagina.Size(PageSizes.A4);
                pagina.Margin(1.2f, Unit.Centimetre);
                pagina.DefaultTextStyle(x => x.FontSize(Letra).FontColor(Colors.Black));

                pagina.Header().Element(e => Encabezado(e, c, opciones));

                pagina.Content().PaddingVertical(10).Column(col =>
                {
                    col.Spacing(8);
                    col.Item().Element(e => Datos(e, c, opciones));
                    col.Item().Element(e => Detalle(e, c, lineas));
                    col.Item().Element(e => Resumen(e, c, totales));
                    col.Item().Element(e => Detraccion(e, c));
                });

                pagina.Footer().Element(e => Pie(e, c, qr, digestFirma, opciones));
            });
        }).GeneratePdf();
    }

    // ------------------------------------------------------------------ partes

    private static void Encabezado(IContainer contenedor, ComprobanteBase c, OpcionesImpresion o)
    {
        contenedor.Border(1).BorderColor(Colors.Black).Padding(8).Row(fila =>
        {
            fila.RelativeItem().Column(col =>
            {
                col.Spacing(1);
                // FitArea y no FitHeight: un logo ancho a 42 pt de alto puede
                // pedir más ancho que el que hay (eso rompía el PDF).
                if (o.Logo is not null)
                    col.Item().Height(42).AlignLeft().Image(o.Logo).FitArea();

                var comercial = string.IsNullOrWhiteSpace(c.Emisor.NombreComercial) ? c.Emisor.RazonSocial : c.Emisor.NombreComercial;
                col.Item().Text(comercial.ToUpperInvariant()).FontSize(11).Bold();
                if (!string.Equals(comercial, c.Emisor.RazonSocial, StringComparison.OrdinalIgnoreCase))
                    col.Item().Text(c.Emisor.RazonSocial).FontSize(9);
                col.Item().Text(c.Emisor.Direccion).FontSize(9);
                col.Item().Text($"{c.Emisor.Distrito} - {c.Emisor.Provincia} - {c.Emisor.Departamento}").FontSize(9);

                // 23 oct: emitido desde un local anexo (sucursal).
                if (!string.IsNullOrWhiteSpace(c.Emisor.DireccionLocal))
                    col.Item().Text(t =>
                    {
                        t.Span("Local: ").FontSize(9).SemiBold();
                        t.Span(c.Emisor.DireccionLocal).FontSize(9);
                    });
            });

            fila.ConstantItem(12);

            fila.ConstantItem(205).Border(1.5f).BorderColor(Colors.Black).Padding(8).Column(col =>
            {
                col.Spacing(3);
                col.Item().AlignCenter().Text(Titulo(c.TipoComprobante)).FontSize(11.5f).Bold();
                col.Item().AlignCenter().Text($"RUC: {c.Emisor.Ruc}").FontSize(11).Bold();
                col.Item().AlignCenter().Text(c.NumeroCompleto).FontSize(11.5f).Bold();
            });
        });
    }

    private static void Datos(IContainer contenedor, ComprobanteBase c, OpcionesImpresion o)
    {
        var factura = c as Factura;

        contenedor.Row(fila =>
        {
            fila.RelativeItem().Table(t =>
            {
                t.ColumnsDefinition(cols =>
                {
                    cols.ConstantColumn(120);
                    cols.ConstantColumn(10);
                    cols.RelativeColumn();
                });

                void Fila(string etiqueta, string? valor)
                {
                    if (string.IsNullOrWhiteSpace(valor)) return;
                    t.Cell().PaddingVertical(1).Text(etiqueta);
                    t.Cell().PaddingVertical(1).Text(":");
                    t.Cell().PaddingVertical(1).Text(valor).SemiBold();
                }

                Fila("Fecha de Emisión", c.FechaEmision.ToString("dd/MM/yyyy", Inv));
                if (factura is not null && ReglasCredito.EsCredito(factura.FormaPago) && factura.Cuotas.Count > 0)
                    Fila("Fecha de Vencimiento", factura.Cuotas.Max(x => x.FechaVencimiento).ToString("dd/MM/yyyy", Inv));
                Fila("Señor(es)", c.Receptor.RazonSocial.ToUpperInvariant());
                Fila(GeneradorPdf.NombreTipoDoc(c.Receptor.TipoDocumento), c.Receptor.NumeroDocumento);
                Fila("Dirección del Cliente", c.Receptor.Direccion.ToUpperInvariant());
                Fila("Tipo de Moneda", NombreMoneda(c.Moneda));
                if (c.TipoCambio is not null)
                    Fila("Tipo de Cambio", c.TipoCambio.Tasa.ToString("F3", Inv));

                if (c is NotaCredito nc)
                {
                    Fila("Documento que modifica", nc.Afectado.Numero);
                    Fila("Motivo", GeneradorPdf.DescripcionMotivo(nc));
                }
                else if (c is NotaDebito nd)
                {
                    Fila("Documento que modifica", nd.Afectado.Numero);
                    Fila("Motivo", string.IsNullOrWhiteSpace(nd.DescripcionMotivo)
                        ? MotivoNotaDebito.Descripcion(nd.CodigoMotivo) : nd.DescripcionMotivo);
                }

                // Los campos propios de la empresa (orden de compra, vendedor…).
                if (o.Extra is { Count: > 0 } extra)
                    foreach (var campo in extra)
                        Fila(GeneradorPdf.EtiquetaExtra(campo.Key), campo.Value);
            });

            fila.ConstantItem(170).AlignRight().Column(col =>
            {
                if (factura is not null)
                    col.Item().AlignRight().Text(t =>
                    {
                        t.Span("Forma de pago: ");
                        t.Span(ReglasCredito.EsCredito(factura.FormaPago) ? "Crédito" : "Contado").SemiBold();
                    });
            });
        });
    }

    private static void Detalle(IContainer contenedor, ComprobanteBase c, IReadOnlyList<LineaCalculada> lineas)
    {
        var conDescuento = lineas.Any(l => l.Descuento > 0);

        contenedor.Border(1).BorderColor(Colors.Black).Table(t =>
        {
            t.ColumnsDefinition(cols =>
            {
                cols.ConstantColumn(52);    // cantidad
                cols.ConstantColumn(62);    // unidad
                cols.RelativeColumn();      // descripción
                cols.ConstantColumn(68);    // valor unitario
                if (conDescuento) cols.ConstantColumn(56);
                cols.ConstantColumn(46);    // ICBPER
                cols.ConstantColumn(70);    // valor de venta
            });

            t.Header(h =>
            {
                Cabecera(h, "Cantidad", true);
                Cabecera(h, "Unidad Medida", false);
                Cabecera(h, "Descripción", false);
                Cabecera(h, "Valor Unitario", true);
                if (conDescuento) Cabecera(h, "Descuento", true);
                Cabecera(h, "ICBPER", true);
                Cabecera(h, "Valor Venta", true);
            });

            foreach (var x in lineas)
            {
                var l = x.Linea;
                var gratuita = AfectacionIgv.EsGratuita(l.TipoAfectacionIgv);

                Celda(t, l.Cantidad.ToString("0.00##", Inv), true);
                Celda(t, NombreUnidad(l.UnidadMedida), false);
                t.Cell().PaddingVertical(3).PaddingHorizontal(4).Column(col =>
                {
                    col.Item().Text(l.Descripcion.ToUpperInvariant());
                    if (!string.IsNullOrWhiteSpace(l.CodigoProducto))
                        col.Item().Text($"Código: {l.CodigoProducto}").FontSize(7);
                    if (gratuita)
                        col.Item().Text("TRANSFERENCIA GRATUITA").FontSize(7).SemiBold();
                });
                Celda(t, F2(l.ValorUnitario), true);
                if (conDescuento) Celda(t, x.Descuento > 0 ? F2(x.Descuento) : "0.00", true);
                Celda(t, F2(x.Icbper), true);
                Celda(t, gratuita ? "0.00" : F2(x.ValorVenta), true);
            }
        });

        static void Cabecera(TableCellDescriptor h, string texto, bool derecha)
        {
            var celda = h.Cell().BorderBottom(1).BorderColor(Colors.Black).PaddingVertical(4).PaddingHorizontal(4);
            (derecha ? celda.AlignRight() : celda).Text(texto).Bold().FontSize(8);
        }

        static void Celda(TableDescriptor t, string texto, bool derecha)
        {
            var celda = t.Cell().PaddingVertical(3).PaddingHorizontal(4);
            (derecha ? celda.AlignRight() : celda).Text(texto);
        }
    }

    private static void Resumen(IContainer contenedor, ComprobanteBase c, TotalesComprobante t)
    {
        var s = GeneradorPdf.SimboloMoneda(c.Moneda);

        contenedor.Row(fila =>
        {
            // --- Izquierda: gratuitas, SON y las cuotas -------------------------
            fila.RelativeItem().PaddingRight(10).Column(col =>
            {
                col.Spacing(8);

                // La etiqueta en un RelativeItem (puede partir en dos líneas): con
                // AutoItem no cabía junto a la caja y el PDF no se generaba.
                col.Item().PaddingTop(18).Row(r =>
                {
                    r.RelativeItem().AlignMiddle().AlignRight().PaddingRight(4)
                        .Text("Valor de Venta de Operaciones Gratuitas :").FontSize(9);
                    r.ConstantItem(90).AlignMiddle().Border(1).BorderColor(Colors.Black).PaddingHorizontal(4).PaddingVertical(2)
                        .AlignRight().Text($"{s} {F2(t.TotalGratuito)}").FontSize(9);
                });

                col.Item().PaddingTop(8).Text($"SON: {Son(t.ImporteTotal, c.Moneda)}").FontSize(10).Bold();

                if (t.TotalGratuito > 0)
                    col.Item().Text(Gratuitas.TextoLeyenda).FontSize(7.5f);
                if (Ivap.Aplica(c))
                    col.Item().Text(Ivap.TextoLeyenda).FontSize(7.5f);

                if (c is Factura f && ReglasCredito.EsCredito(f.FormaPago) && f.Cuotas.Count > 0)
                {
                    col.Item().Column(cc =>
                    {
                        cc.Item().Text($"Pago al crédito en {f.Cuotas.Count} cuota{(f.Cuotas.Count == 1 ? "" : "s")}").SemiBold();
                        foreach (var q in f.Cuotas.OrderBy(x => x.Numero))
                            cc.Item().Text($"Cuota {q.Numero}: {s} {F2(q.Monto)} — vence el {q.FechaVencimiento.ToString("dd/MM/yyyy", Inv)}")
                                .FontSize(8);
                    });
                }

                // Qué son los cargos y descuentos globales (no está en el XML).
                if (c.CargosGlobales.Count > 0)
                {
                    col.Item().Column(cc =>
                    {
                        cc.Item().Text("Cargos y descuentos").SemiBold();
                        foreach (var cg in c.CargosGlobales)
                            cc.Item().Text(
                                (string.IsNullOrWhiteSpace(cg.Descripcion) ? CodigoCargoDescuento.Descripcion(cg.Codigo) : cg.Descripcion) +
                                $": {(cg.EsCargo ? "" : "- ")}{s} {F2(cg.Monto)}" +
                                (CodigoCargoDescuento.AfectaLaBase(cg.Codigo) ? " (incluido en el valor de venta)" : ""))
                                .FontSize(8);
                    });
                }
            });

            // --- Derecha: el cuadro de totales ------------------------------------
            fila.ConstantItem(270).Border(1).BorderColor(Colors.Black).Padding(6).Column(col =>
            {
                col.Spacing(2);

                Fila(col, "Sub Total Ventas", s, t.ValorVenta + t.TotalDescuentos);
                Fila(col, "Descuentos", s, t.TotalDescuentos);
                Fila(col, "Valor Venta", s, t.ValorVenta);
                Fila(col, "ISC", s, t.TotalIsc);
                if (t.HayIvap) Fila(col, $"IVAP ({Ivap.Tasa:0.##}%)", s, t.TotalIvap);
                else Fila(col, "IGV", s, t.TotalIgv);
                Fila(col, "ICBPER", s, t.TotalIcbper);
                Fila(col, "Otros Cargos", s, t.TotalOtrosCargos);
                Fila(col, "Otros Descuentos", s, t.TotalOtrosDescuentos);
                Fila(col, "Anticipos", s, t.TotalAnticipos);
                Fila(col, "Importe Total", s, t.ImporteTotal, total: true);

                // La percepción: el cliente paga más de lo que dice el total.
                if (c is Factura f && f.Percepcion is not null)
                {
                    Fila(col, $"Percepción ({f.Percepcion.Porcentaje.ToString("0.##", Inv)}%)", "S/", f.Percepcion.Monto);
                    Fila(col, "Total a pagar", "S/", f.Percepcion.TotalConPercepcion, total: true);
                }
            });
        });

        static void Fila(ColumnDescriptor col, string etiqueta, string simbolo, decimal monto, bool total = false) =>
            col.Item().Row(r =>
            {
                var e = r.RelativeItem().AlignRight().PaddingRight(6).AlignMiddle().Text($"{etiqueta} :");
                if (total) e.FontSize(10.5f).SemiBold();
                var caja = r.ConstantItem(105).Border(0.75f).BorderColor(Colors.Black).PaddingHorizontal(4).PaddingVertical(1).AlignRight();
                var v = caja.Text($"{simbolo} {F2(monto)}");
                if (total) v.FontSize(10.5f).Bold();
            });
    }

    private static void Detraccion(IContainer contenedor, ComprobanteBase c)
    {
        if (c is not Factura { Detraccion: { } d })
        {
            contenedor.Text("");
            return;
        }

        contenedor.Border(1).BorderColor(Colors.Black).Padding(6).Column(col =>
        {
            col.Spacing(2);
            col.Item().Text("Información de la detracción").Bold();

            col.Item().Table(t =>
            {
                t.ColumnsDefinition(cols =>
                {
                    cols.ConstantColumn(120);
                    cols.RelativeColumn();
                });
                void F(string a, string b) { t.Cell().Text(a); t.Cell().Text(b); }

                F("Leyenda:", "Operación sujeta al Sistema de Pago de Obligaciones Tributarias con el Gobierno Central");
                F("Bien o Servicio:", $"{d.CodigoBienServicio}  {BienServicio(d.CodigoBienServicio)}");
                F("Medio de pago:", $"{d.MedioDePago}  {MedioPago(d.MedioDePago)}");
            });

            col.Item().Row(r =>
            {
                r.RelativeItem().Text(t => { t.Span("Nro. Cta. Banco de la Nación:  "); t.Span(d.CuentaBancoNacion).SemiBold(); });
                r.RelativeItem().Text(t => { t.Span("Porcentaje de detracción:  "); t.Span($"{d.Porcentaje.ToString("0.00", Inv)} %").SemiBold(); });
                r.RelativeItem().AlignRight().Text(t => { t.Span("Monto detracción:  "); t.Span($"S/ {F2(d.Monto)}").SemiBold(); });
            });
        });
    }

    private static void Pie(IContainer contenedor, ComprobanteBase c, byte[] qr, string? digest, OpcionesImpresion o)
    {
        contenedor.Border(1).BorderColor(Colors.Black).Padding(6).Row(fila =>
        {
            fila.ConstantItem(64).Height(64).Image(qr).FitArea();
            fila.ConstantItem(10);
            fila.RelativeItem().AlignMiddle().Column(col =>
            {
                col.Spacing(2);
                col.Item().Text($"Representación impresa de la {Nombre(c.TipoComprobante)}.").FontSize(9.5f).Italic();
                col.Item().Text("Puede verificarla en el portal de SUNAT (www.sunat.gob.pe) con el código QR.")
                    .FontSize(8).Italic();
                if (!string.IsNullOrWhiteSpace(digest))
                    col.Item().Text($"Valor resumen: {digest}").FontSize(7);
                if (!string.IsNullOrWhiteSpace(o.EstadoSunat))
                    col.Item().Text(t =>
                    {
                        t.Span("Estado: ").FontSize(7.5f).SemiBold();
                        t.Span(o.EstadoSunat).FontSize(7.5f);
                    });
            });
        });
    }

    // ---------------------------------------------------------------- textos

    private static string F2(decimal v) => v.ToString("N2", Inv);

    private static string Titulo(string tipo) => tipo switch
    {
        TipoComprobante.Factura => "FACTURA ELECTRÓNICA",
        TipoComprobante.Boleta => "BOLETA DE VENTA ELECTRÓNICA",
        TipoComprobante.NotaCredito => "NOTA DE CRÉDITO ELECTRÓNICA",
        TipoComprobante.NotaDebito => "NOTA DE DÉBITO ELECTRÓNICA",
        _ => "COMPROBANTE ELECTRÓNICO"
    };

    private static string Nombre(string tipo) => tipo switch
    {
        TipoComprobante.Factura => "Factura Electrónica",
        TipoComprobante.Boleta => "Boleta de Venta Electrónica",
        TipoComprobante.NotaCredito => "Nota de Crédito Electrónica",
        TipoComprobante.NotaDebito => "Nota de Débito Electrónica",
        _ => "comprobante electrónico"
    };

    private static string NombreMoneda(string m) => m switch
    {
        "PEN" => "SOLES",
        "USD" => "DÓLAR AMERICANO",
        "EUR" => "EURO",
        _ => m
    };

    /// <summary>«CUATROCIENTOS NOVENTA Y 62/100 DOLAR AMERICANO», sin el «SON» que ya trae la leyenda.</summary>
    private static string Son(decimal total, string moneda)
    {
        var texto = NumeroALetras.Leyenda(total, moneda).Trim();
        return texto.StartsWith("SON ", StringComparison.OrdinalIgnoreCase) || texto.StartsWith("SON:", StringComparison.OrdinalIgnoreCase)
            ? texto[3..].TrimStart(':', ' ')
            : texto;
    }

    private static readonly Dictionary<string, string> Unidades = new(StringComparer.OrdinalIgnoreCase)
    {
        ["NIU"] = "UNIDAD", ["ZZ"] = "SERVICIO", ["KGM"] = "KILOGRAMO", ["GRM"] = "GRAMO", ["LTR"] = "LITRO",
        ["MTR"] = "METRO", ["MTK"] = "METRO CUAD.", ["MTQ"] = "METRO CÚB.", ["BX"] = "CAJA", ["PK"] = "PAQUETE",
        ["DZN"] = "DOCENA", ["MIL"] = "MILLAR", ["TNE"] = "TONELADA", ["GLL"] = "GALÓN", ["HUR"] = "HORA",
        ["DAY"] = "DÍA", ["MON"] = "MES", ["SET"] = "JUEGO", ["PR"] = "PAR", ["BG"] = "BOLSA", ["BO"] = "BOTELLA",
        ["CEN"] = "CIENTO", ["KT"] = "KIT", ["RO"] = "ROLLO", ["4A"] = "BOBINA", ["CMT"] = "CENTÍMETRO",
    };

    private static string NombreUnidad(string codigo) =>
        Unidades.TryGetValue(codigo ?? "", out var n) ? n : codigo ?? "";

    /// <summary>Catálogo 54 (bienes y servicios sujetos a detracción), con el nombre corto.</summary>
    private static readonly Dictionary<string, string> Bienes = new()
    {
        ["001"] = "Azúcar y melaza de caña", ["003"] = "Alcohol etílico", ["004"] = "Recursos hidrobiológicos",
        ["005"] = "Maíz amarillo duro", ["007"] = "Caña de azúcar", ["008"] = "Madera", ["009"] = "Arena y piedra",
        ["010"] = "Residuos, subproductos, desechos, recortes y desperdicios", ["011"] = "Bienes gravados con el IGV, o renuncia a la exoneración",
        ["012"] = "Intermediación laboral y tercerización", ["013"] = "Animales vivos", ["014"] = "Carnes y despojos comestibles",
        ["015"] = "Abonos, cueros y pieles de origen animal", ["016"] = "Aceite de pescado",
        ["017"] = "Harina, polvo y pellets de pescado, crustáceos, moluscos y demás invertebrados acuáticos",
        ["019"] = "Arrendamiento de bienes", ["020"] = "Mantenimiento y reparación de bienes muebles", ["021"] = "Movimiento de carga",
        ["022"] = "Otros servicios empresariales", ["023"] = "Leche", ["024"] = "Comisión mercantil",
        ["025"] = "Fabricación de bienes por encargo", ["026"] = "Servicio de transporte de personas",
        ["027"] = "Servicio de transporte de carga", ["028"] = "Transporte de pasajeros", ["030"] = "Contratos de construcción",
        ["031"] = "Oro gravado con el IGV", ["032"] = "Páprika y otros frutos de los géneros capsicum o pimienta",
        ["034"] = "Minerales metálicos no auríferos", ["035"] = "Bienes exonerados del IGV",
        ["036"] = "Oro y demás minerales metálicos exonerados del IGV", ["037"] = "Demás servicios gravados con el IGV",
        ["039"] = "Minerales no metálicos", ["040"] = "Bien inmueble gravado con IGV", ["041"] = "Plomo",
    };

    private static string BienServicio(string codigo) => Bienes.TryGetValue(codigo, out var n) ? n : "";

    /// <summary>Catálogo 59 (medios de pago).</summary>
    private static readonly Dictionary<string, string> Medios = new()
    {
        ["001"] = "Depósito en cuenta", ["002"] = "Giro", ["003"] = "Transferencia de fondos", ["004"] = "Orden de pago",
        ["005"] = "Tarjeta de débito", ["006"] = "Tarjeta de crédito", ["007"] = "Cheque no negociable",
        ["008"] = "Efectivo, sin obligación de medio de pago", ["009"] = "Efectivo, en los demás casos",
        ["010"] = "Medios de pago de comercio exterior", ["999"] = "Otros medios de pago",
    };

    private static string MedioPago(string codigo) => Medios.TryGetValue(codigo ?? "", out var n) ? n : "";
}