using System.Globalization;
using Facturacion.Cpe;
using QuestPDF.Fluent;
using QuestPDF.Helpers;
using QuestPDF.Infrastructure;

namespace Facturacion.Pdf;

/// <summary>Datos de presentación que no viven en el comprobante.</summary>
public record OpcionesImpresion(
    string? EstadoSunat = null,
    string? MensajeSunat = null,
    byte[]? Logo = null)
{
    public static readonly OpcionesImpresion PorDefecto = new();
}

/// <summary>
/// Genera la representación impresa del comprobante.
///
/// QUÉ ES Y QUÉ NO ES:
///
/// El PDF NO es el comprobante. El comprobante es el XML firmado; esto es su
/// representación para que una persona lo lea. Si ambos difieren, vale el XML.
///
/// Eso tiene una consecuencia práctica agradable: aquí hay libertad de diseño.
/// SUNAT exige que aparezcan ciertos datos, pero la forma es tuya, y cada
/// cliente va a querer la suya. Por eso conviene que este generador sea fácil
/// de variar: es lo primero que te van a pedir cambiar.
///
/// SOBRE LA LICENCIA DE QuestPDF: la licencia Community es gratuita para
/// organizaciones por debajo de cierto nivel de facturación anual. Por encima
/// de ese umbral hay que pagar licencia. Conviene verificar los términos
/// vigentes antes de venderlo a clientes grandes.
/// </summary>
public static class GeneradorPdf
{
    private static readonly CultureInfo Inv = CultureInfo.InvariantCulture;

    private static bool _licenciaConfigurada;

    /// <summary>
    /// Declara la licencia Community de QuestPDF.
    ///
    /// Sin esta llamada, la librería lanza una excepción al generar el primer
    /// documento. Se hace una sola vez por proceso.
    /// </summary>
    public static void ConfigurarLicencia()
    {
        if (_licenciaConfigurada) return;

        QuestPDF.Settings.License = LicenseType.Community;
        _licenciaConfigurada = true;
    }

    public static byte[] Generar(
        ComprobanteBase comprobante,
        string? digestFirma,
        OpcionesImpresion? opciones = null)
    {
        ConfigurarLicencia();

        opciones ??= OpcionesImpresion.PorDefecto;

        var totales = CalculadoraTotales.Calcular(comprobante);
        var lineas = CalculadoraTotales.CalcularLineas(comprobante);

        var textoQr = CodigoQr.Contenido(comprobante, totales, digestFirma);
        var imagenQr = CodigoQr.GenerarPng(textoQr);

        var documento = Document.Create(contenedor =>
        {
            contenedor.Page(pagina =>
            {
                pagina.Size(PageSizes.A4);
                pagina.Margin(1.5f, Unit.Centimetre);
                // SE USA LATO, QUE VIENE INCLUIDA CON QuestPDF.
                //
                // Pedir una fuente del sistema, como Calibri o Arial, produce
                // una excepción si esa fuente no está instalada donde corre el
                // proceso. Y en un contenedor Linux no hay ninguna fuente de
                // Windows: el PDF fallaría solo en producción, que es el peor
                // momento para descubrirlo.
                //
                // QuestPDF no usa las fuentes del sistema por defecto, y es
                // deliberado: así el documento sale idéntico en tu máquina y
                // en el servidor.
                //
                // Si algún cliente quiere su tipografía corporativa, se
                // despliega el archivo .ttf junto a la aplicación y se
                // registra con FontManager.
                pagina.DefaultTextStyle(x => x.FontSize(9));

                pagina.Header().Element(e =>
                    Encabezado(e, comprobante, opciones));

                pagina.Content().PaddingVertical(12).Column(columna =>
                {
                    columna.Spacing(10);

                    columna.Item().Element(e => DatosReceptor(e, comprobante));
                    columna.Item().Element(e => Detalle(e, comprobante, lineas));
                    columna.Item().Element(e => Totales(e, comprobante, totales));
                    columna.Item().Element(e => Leyenda(e, comprobante, totales));
                });

                pagina.Footer().Element(e =>
                    PiePagina(e, imagenQr, opciones));
            });
        });

        return documento.GeneratePdf();
    }

    // ------------------------------------------------------------- secciones

    private static void Encabezado(
        IContainer contenedor, ComprobanteBase c, OpcionesImpresion opciones)
    {
        contenedor.Row(fila =>
        {
            // Datos del emisor
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

            // El recuadro con el RUC y el número. Es el elemento más
            // reconocible de un comprobante peruano y por eso va enmarcado.
            fila.ConstantItem(190)
                .Border(1).BorderColor(Colors.Grey.Darken1)
                .Padding(8)
                .Column(columna =>
                {
                    columna.Spacing(3);

                    columna.Item().AlignCenter()
                        .Text($"R.U.C. {c.Emisor.Ruc}")
                        .FontSize(11).Bold();

                    columna.Item().AlignCenter()
                        .Text(NombreDocumento(c.TipoComprobante))
                        .FontSize(11).Bold();

                    columna.Item().AlignCenter()
                        .Text(c.NumeroCompleto)
                        .FontSize(12).Bold();
                });
        });
    }

    private static void DatosReceptor(IContainer contenedor, ComprobanteBase c)
    {
        contenedor
            .Background(Colors.Grey.Lighten4)
            .Padding(8)
            .Column(columna =>
            {
                columna.Spacing(2);

                columna.Item().Row(fila =>
                {
                    fila.RelativeItem().Text(t =>
                    {
                        t.Span("Cliente: ").SemiBold();
                        t.Span(c.Receptor.RazonSocial);
                    });

                    fila.ConstantItem(200).Text(t =>
                    {
                        t.Span($"{NombreTipoDoc(c.Receptor.TipoDocumento)}: ").SemiBold();
                        t.Span(c.Receptor.NumeroDocumento);
                    });
                });

                if (!string.IsNullOrWhiteSpace(c.Receptor.Direccion))
                {
                    columna.Item().Text(t =>
                    {
                        t.Span("Dirección: ").SemiBold();
                        t.Span(c.Receptor.Direccion);
                    });
                }

                columna.Item().Row(fila =>
                {
                    fila.RelativeItem().Text(t =>
                    {
                        t.Span("Fecha de emisión: ").SemiBold();
                        t.Span(c.FechaEmision.ToString("dd/MM/yyyy", Inv));
                    });

                    fila.ConstantItem(200).Text(t =>
                    {
                        t.Span("Moneda: ").SemiBold();
                        t.Span(NombreMoneda(c.Moneda));
                    });
                });

                // Las notas deben decir qué documento modifican: sin eso,
                // quien la recibe no sabe a qué factura corresponde.
                if (c is NotaCredito nc)
                {
                    columna.Item().Text(t =>
                    {
                        t.Span("Modifica a: ").SemiBold();
                        t.Span($"{nc.Afectado.Numero}  —  {DescripcionMotivo(nc)}");
                    });
                }
                else if (c is NotaDebito nd)
                {
                    columna.Item().Text(t =>
                    {
                        t.Span("Modifica a: ").SemiBold();
                        t.Span($"{nd.Afectado.Numero}  —  {MotivoNotaDebito.Descripcion(nd.CodigoMotivo)}");
                    });
                }
            });
    }

    private static void Detalle(
        IContainer contenedor, ComprobanteBase c, IReadOnlyList<LineaCalculada> lineas)
    {
        contenedor.Table(tabla =>
        {
            tabla.ColumnsDefinition(columnas =>
            {
                columnas.ConstantColumn(28);    // ítem
                columnas.ConstantColumn(50);    // cantidad
                columnas.ConstantColumn(38);    // unidad
                columnas.RelativeColumn();      // descripción
                columnas.ConstantColumn(62);    // valor unitario
                columnas.ConstantColumn(58);    // descuento
                columnas.ConstantColumn(66);    // importe
            });

            tabla.Header(cabecera =>
            {
                Titulo(cabecera, "#");
                Titulo(cabecera, "Cant.");
                Titulo(cabecera, "Und.");
                Titulo(cabecera, "Descripción");
                Titulo(cabecera, "V. Unit.", alinearDerecha: true);
                Titulo(cabecera, "Dscto.", alinearDerecha: true);
                Titulo(cabecera, "Importe", alinearDerecha: true);
            });

            foreach (var calculada in lineas)
            {
                var l = calculada.Linea;

                Celda(tabla, l.Numero.ToString(Inv));
                Celda(tabla, l.Cantidad.ToString("0.##", Inv));
                Celda(tabla, l.UnidadMedida);

                tabla.Cell().PaddingVertical(4).PaddingHorizontal(3).Column(columna =>
                {
                    columna.Item().Text(l.Descripcion);

                    if (!string.IsNullOrWhiteSpace(l.CodigoProducto))
                        columna.Item().Text(l.CodigoProducto)
                            .FontSize(7).FontColor(Colors.Grey.Darken1);
                });

                Celda(tabla, F2(l.ValorUnitario), alinearDerecha: true);

                Celda(tabla,
                    calculada.Descuento > 0 ? F2(calculada.Descuento) : "",
                    alinearDerecha: true);

                Celda(tabla, F2(calculada.ValorVenta), alinearDerecha: true);
            }
        });

        // OJO CON LOS TIPOS: dentro de Header(...) QuestPDF entrega un
        // TableCellDescriptor, mientras que fuera se usa TableDescriptor.
        // Los dos tienen Cell(), pero no son el mismo tipo, y confundirlos
        // produce un error que habla de conversiones y no de tablas.
        static void Titulo(TableCellDescriptor t, string texto, bool alinearDerecha = false)
        {
            var celda = t.Cell()
                .Background(Colors.Grey.Lighten2)
                .PaddingVertical(5).PaddingHorizontal(3);

            (alinearDerecha ? celda.AlignRight() : celda)
                .Text(texto).SemiBold().FontSize(8);
        }

        static void Celda(TableDescriptor t, string texto, bool alinearDerecha = false)
        {
            var celda = t.Cell()
                .BorderBottom(0.5f).BorderColor(Colors.Grey.Lighten2)
                .PaddingVertical(4).PaddingHorizontal(3);

            (alinearDerecha ? celda.AlignRight() : celda).Text(texto);
        }
    }

    private static void Totales(
        IContainer contenedor, ComprobanteBase c, TotalesComprobante t)
    {
        contenedor.AlignRight().Width(230).Column(columna =>
        {
            var simbolo = SimboloMoneda(c.Moneda);

            // Solo se muestran los importes que existen. Una fila con cero
            // no aporta nada y hace más difícil encontrar lo que sí importa.
            if (t.TotalDescuentos > 0)
                Linea(columna, "Descuentos", simbolo, t.TotalDescuentos);

            if (t.TotalGravado > 0)
                Linea(columna, "Op. gravadas", simbolo, t.TotalGravado);

            if (t.TotalExonerado > 0)
                Linea(columna, "Op. exoneradas", simbolo, t.TotalExonerado);

            if (t.TotalInafecto > 0)
                Linea(columna, "Op. inafectas", simbolo, t.TotalInafecto);

            if (t.TotalGratuito > 0)
                Linea(columna, "Op. gratuitas", simbolo, t.TotalGratuito);

            Linea(columna, "IGV", simbolo, t.TotalIgv);

            columna.Item().PaddingTop(3).BorderTop(1)
                .BorderColor(Colors.Grey.Darken1).PaddingTop(4)
                .Row(fila =>
                {
                    fila.RelativeItem().Text("IMPORTE TOTAL").Bold();
                    fila.ConstantItem(95).AlignRight()
                        .Text($"{simbolo} {F2(t.ImporteTotal)}").Bold().FontSize(11);
                });
        });

        static void Linea(ColumnDescriptor c, string etiqueta, string simbolo, decimal monto) =>
            c.Item().Row(fila =>
            {
                fila.RelativeItem().Text(etiqueta);
                fila.ConstantItem(95).AlignRight().Text($"{simbolo} {F2(monto)}");
            });
    }

    private static void Leyenda(
        IContainer contenedor, ComprobanteBase c, TotalesComprobante t)
    {
        contenedor.Column(columna =>
        {
            columna.Item().Text(
                NumeroALetras.Leyenda(t.ImporteTotal, c.Moneda))
                .FontSize(8).SemiBold();
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
                        "Representación impresa del comprobante de pago electrónico.")
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

    // ------------------------------------------------------------- auxiliares

    private static string F2(decimal valor) => valor.ToString("N2", Inv);

    private static string NombreDocumento(string tipo) => tipo switch
    {
        TipoComprobante.Factura     => "FACTURA ELECTRÓNICA",
        TipoComprobante.Boleta      => "BOLETA DE VENTA ELECTRÓNICA",
        TipoComprobante.NotaCredito => "NOTA DE CRÉDITO ELECTRÓNICA",
        TipoComprobante.NotaDebito  => "NOTA DE DÉBITO ELECTRÓNICA",
        _                           => "COMPROBANTE ELECTRÓNICO"
    };

    private static string NombreTipoDoc(string tipo) => tipo switch
    {
        TipoDocIdentidad.Ruc         => "RUC",
        TipoDocIdentidad.Dni         => "DNI",
        TipoDocIdentidad.Pasaporte   => "Pasaporte",
        TipoDocIdentidad.Extranjeria => "C. Extranjería",
        _                            => "Documento"
    };

    private static string NombreMoneda(string moneda) => moneda switch
    {
        "PEN" => "Soles",
        "USD" => "Dólares americanos",
        "EUR" => "Euros",
        _     => moneda
    };

    private static string SimboloMoneda(string moneda) => moneda switch
    {
        "PEN" => "S/",
        "USD" => "US$",
        "EUR" => "€",
        _     => moneda
    };

    private static string DescripcionMotivo(NotaCredito n) =>
        string.IsNullOrWhiteSpace(n.DescripcionMotivo)
            ? MotivoNotaCredito.Descripcion(n.CodigoMotivo)
            : n.DescripcionMotivo;
}
