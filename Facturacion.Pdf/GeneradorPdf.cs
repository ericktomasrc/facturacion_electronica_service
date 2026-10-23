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
    byte[]? Logo = null,

    // Campos propios de la empresa que se imprimen y no viajan a SUNAT.
    // La clave es como la mandó quien integra ("ordenCompra") y el
    // generador se encarga de convertirla en una etiqueta legible.
    IReadOnlyDictionary<string, string>? Extra = null)
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
/// PERO LA LIBERTAD TIENE UN LÍMITE, Y AQUÍ SE HABÍA CRUZADO: los importes
/// que se muestran tienen que sumar lo que dice el total. Este generador se
/// quedó en la versión de hace semanas y no declaraba los anticipos, la
/// detracción, la percepción ni los cargos globales — así que una factura con
/// anticipo enseñaba un valor de venta de 10 000, un IGV de 1 800 y un total
/// de 9 440, sin nada que explicara la diferencia. El XML estaba bien; el
/// papel parecía mal sumado, y es el papel lo que el cliente mira.
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

                    columna.Item().Element(e => DatosReceptor(e, comprobante, opciones));
                    columna.Item().Element(e => Detalle(e, comprobante, lineas));
                    columna.Item().Element(e => Totales(e, comprobante, totales));
                    columna.Item().Element(e => Leyenda(e, comprobante, totales));
                    columna.Item().Element(e => Condiciones(e, comprobante));
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

                // 23 oct: emitido desde un local anexo (sucursal).
                if (!string.IsNullOrWhiteSpace(c.Emisor.DireccionLocal))
                    columna.Item().Text(t =>
                    {
                        t.Span("Local: ").FontSize(8).SemiBold();
                        t.Span(c.Emisor.DireccionLocal).FontSize(8);
                    });
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

    private static void DatosReceptor(
        IContainer contenedor, ComprobanteBase c, OpcionesImpresion opciones)
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
                        // LA FECHA DE EMISIÓN NO SE CONVIERTE, Y ES CORRECTO.
                        //
                        // Ya viene en hora de Perú: la puso RelojPeru.Ahora
                        // cuando se emitió. Aplicarle una conversión aquí la
                        // movería un día en los comprobantes de la noche.
                        t.Span("Fecha de emisión: ").SemiBold();
                        t.Span(c.FechaEmision.ToString("dd/MM/yyyy", Inv));
                    });

                    fila.ConstantItem(200).Text(t =>
                    {
                        t.Span("Moneda: ").SemiBold();
                        t.Span(NombreMoneda(c.Moneda));
                    });
                });

                // La forma de pago, que el cliente busca antes que nada.
                if (c is Factura factura)
                {
                    columna.Item().Row(fila =>
                    {
                        fila.RelativeItem().Text(t =>
                        {
                            t.Span("Condición de pago: ").SemiBold();
                            t.Span(ReglasCredito.EsCredito(factura.FormaPago)
                                ? "Crédito"
                                : "Contado");
                        });

                        if (c.TipoCambio is not null)
                        {
                            fila.ConstantItem(200).Text(t =>
                            {
                                t.Span("Tipo de cambio: ").SemiBold();
                                t.Span(c.TipoCambio.Tasa.ToString("F3", Inv));
                            });
                        }
                        else
                        {
                            fila.ConstantItem(200);
                        }
                    });
                }

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

                // LOS CAMPOS PROPIOS DE LA EMPRESA, AL PIE DEL BLOQUE.
                //
                // El estándar de SUNAT no tiene sitio para la orden de compra
                // del cliente, ni para un centro de costo, ni para el nombre
                // del vendedor. Esos datos no viajan en el XML y este papel es
                // el único lugar donde el cliente puede leerlos.
                //
                // No es un adorno: hay empresas que no pagan una factura que
                // no traiga impreso su número de orden de compra.
                //
                // Van al final y no junto a la fecha a propósito: son
                // variables en número y en largo, y meterlos en la rejilla de
                // dos columnas descuadraría el bloque en cuanto uno sea largo.
                if (opciones.Extra is { Count: > 0 } extra)
                {
                    foreach (var campo in extra)
                    {
                        columna.Item().Text(t =>
                        {
                            t.Span($"{EtiquetaExtra(campo.Key)}: ").SemiBold();
                            t.Span(campo.Value);
                        });
                    }
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
                var esGratuita = AfectacionIgv.EsGratuita(l.TipoAfectacionIgv);

                Celda(tabla, l.Numero.ToString(Inv));
                Celda(tabla, l.Cantidad.ToString("0.##", Inv));
                Celda(tabla, l.UnidadMedida);

                tabla.Cell().PaddingVertical(4).PaddingHorizontal(3).Column(columna =>
                {
                    columna.Item().Text(l.Descripcion);

                    if (!string.IsNullOrWhiteSpace(l.CodigoProducto))
                        columna.Item().Text(l.CodigoProducto)
                            .FontSize(7).FontColor(Colors.Grey.Darken1);

                    // UNA LÍNEA GRATUITA TIENE QUE VERSE COMO GRATUITA.
                    //
                    // Su importe aparece en la columna de la derecha igual
                    // que el de las demás, pero no se cobra. Sin esta marca,
                    // el cliente suma los importes, no le da el total, y
                    // llama para preguntar qué está mal.
                    if (esGratuita)
                        columna.Item().Text("TRANSFERENCIA GRATUITA — no se cobra")
                            .FontSize(7).SemiBold().FontColor(Colors.Grey.Darken2);

                    // Cuántas bolsas y a cuánto. El cliente ve un cargo que
                    // no pidió, y tiene derecho a saber de dónde sale.
                    if (calculada.TieneIcbper)
                        columna.Item().Text(
                            $"ICBPER: {l.Cantidad.ToString("0", Inv)} x " +
                            $"S/ {F2(calculada.TasaIcbper)} = " +
                            $"S/ {F2(calculada.Icbper)}")
                            .FontSize(7).FontColor(Colors.Grey.Darken2);
                });

                Celda(tabla, F2(l.ValorUnitario), alinearDerecha: true);

                Celda(tabla,
                    calculada.Descuento > 0 ? F2(calculada.Descuento) : "",
                    alinearDerecha: true);

                Celda(tabla,
                    esGratuita ? "0.00" : F2(calculada.ValorVenta),
                    alinearDerecha: true);
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

    /// <summary>
    /// El bloque de totales.
    ///
    /// LA REGLA QUE MANDA AQUÍ: lo que se imprime tiene que sumar. Si el
    /// cliente coge una calculadora y las cifras no le dan el total, el
    /// documento pierde credibilidad aunque el XML sea perfecto.
    ///
    /// Por eso aparece TODO lo que mueve el importe: los anticipos que se
    /// restan, los cargos que se suman, los descuentos globales. Y lo que
    /// NO mueve el importe —las operaciones gratuitas, la percepción— va
    /// separado y dicho con todas las letras, para que nadie lo sume por su
    /// cuenta.
    /// </summary>
    private static void Totales(
        IContainer contenedor, ComprobanteBase c, TotalesComprobante t)
    {
        contenedor.AlignRight().Width(250).Column(columna =>
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

            // FALTABA, Y SE NOTABA: una factura de exportación mostraba el
            // IGV en cero y ninguna línea con el valor de venta.
            if (t.TotalExportacion > 0)
                Linea(columna, "Op. de exportación", simbolo, t.TotalExportacion);

            // El arroz pilado no paga IGV: paga IVAP. Poner "IGV" sobre un
            // 4% confundiria al contador del cliente, que es quien revisa
            // estos papeles.
            if (t.HayIvap)
            {
                Linea(columna, "Op. gravadas IVAP", simbolo, t.TotalGravadoIvap);
                Linea(columna, $"IVAP ({Ivap.Tasa:0.##}%)", simbolo, t.TotalIvap);
            }
            else
            {
                Linea(columna, "IGV", simbolo, t.TotalIgv);
            }

            // EL ISC VA ANTES DEL IGV, y en el papel también: así el cliente
            // ve de dónde sale la base sobre la que se calculó el impuesto.
            if (t.TotalIsc > 0)
                Linea(columna, "ISC", simbolo, t.TotalIsc);

            // El impuesto de las bolsas, con su nombre en claro: "ICBPER" a
            // secas no lo entiende nadie que no trabaje en esto.
            if (t.TotalIcbper > 0)
                Linea(columna, "ICBPER (bolsas plásticas)", simbolo, t.TotalIcbper);

            // --- Lo que mueve el importe a pagar ------------------------------

            if (t.TotalOtrosCargos > 0)
                Linea(columna, "Otros cargos", simbolo, t.TotalOtrosCargos);

            if (t.TotalOtrosDescuentos > 0)
                Linea(columna, "Otros descuentos", simbolo, -t.TotalOtrosDescuentos);

            if (t.TotalAnticipos > 0)
                Linea(columna, "Anticipos aplicados", simbolo, -t.TotalAnticipos);

            columna.Item().PaddingTop(3).BorderTop(1)
                .BorderColor(Colors.Grey.Darken1).PaddingTop(4)
                .Row(fila =>
                {
                    fila.RelativeItem().Text("IMPORTE TOTAL").Bold();
                    fila.ConstantItem(105).AlignRight()
                        .Text($"{simbolo} {F2(t.ImporteTotal)}").Bold().FontSize(11);
                });

            // --- Lo que NO está dentro del importe total -----------------------
            //
            // La percepción es el caso delicado: el cliente paga más de lo
            // que dice el IMPORTE TOTAL, y si el papel no lo dice, se entera
            // al recibir el cobro.

            if (c is Factura f && f.Percepcion is not null)
            {
                columna.Item().PaddingTop(6).Row(fila =>
                {
                    fila.RelativeItem().Text(
                        $"Percepción ({f.Percepcion.Porcentaje.ToString("0.##", Inv)}%)");
                    fila.ConstantItem(105).AlignRight()
                        .Text($"S/ {F2(f.Percepcion.Monto)}");
                });

                columna.Item().PaddingTop(2).Row(fila =>
                {
                    fila.RelativeItem().Text("TOTAL A PAGAR").SemiBold();
                    fila.ConstantItem(105).AlignRight()
                        .Text($"S/ {F2(f.Percepcion.TotalConPercepcion)}")
                        .SemiBold().FontSize(10);
                });
            }

            // Las gratuitas van fuera de la suma, con su nombre.
            if (t.TotalGratuito > 0)
            {
                columna.Item().PaddingTop(6).Row(fila =>
                {
                    fila.RelativeItem().Text("Op. gratuitas (no se cobran)")
                        .FontSize(8).FontColor(Colors.Grey.Darken2);
                    fila.ConstantItem(105).AlignRight()
                        .Text($"{simbolo} {F2(t.TotalGratuito)}")
                        .FontSize(8).FontColor(Colors.Grey.Darken2);
                });
            }
        });

        static void Linea(ColumnDescriptor c, string etiqueta, string simbolo, decimal monto) =>
            c.Item().Row(fila =>
            {
                fila.RelativeItem().Text(etiqueta);

                // Los importes negativos se escriben con el signo delante del
                // símbolo, no dentro: "- S/ 150.00" y no "S/ -150.00".
                fila.ConstantItem(105).AlignRight().Text(monto < 0
                    ? $"- {simbolo} {F2(-monto)}"
                    : $"{simbolo} {F2(monto)}");
            });
    }

    private static void Leyenda(
        IContainer contenedor, ComprobanteBase c, TotalesComprobante t)
    {
        contenedor.Column(columna =>
        {
            columna.Spacing(3);

            columna.Item().Text(
                NumeroALetras.Leyenda(t.ImporteTotal, c.Moneda))
                .FontSize(8).SemiBold();

            // Las mismas leyendas que viajan en el XML. Si SUNAT obliga a
            // declararlas, el papel tampoco puede callarlas.
            if (t.TotalGratuito > 0)
                columna.Item().Text(Gratuitas.TextoLeyenda)
                    .FontSize(7.5f).FontColor(Colors.Grey.Darken2);

            if (c is Factura f && f.Detraccion is not null)
                columna.Item().Text(Detraccion.TextoLeyenda)
                    .FontSize(7.5f).FontColor(Colors.Grey.Darken2);

            if (Ivap.Aplica(c))
                columna.Item().Text(Ivap.TextoLeyenda)
                    .FontSize(7.5f).FontColor(Colors.Grey.Darken2);
        });
    }

    /// <summary>
    /// Las condiciones de cobro: cuotas, detracción y los conceptos globales
    /// con su descripción.
    ///
    /// ESTO NO ESTÁ EN EL XML DE LA MISMA FORMA. La descripción de un cargo
    /// global no tiene sitio en el estándar, así que el papel es el único
    /// lugar donde el cliente puede leer que esos 150 soles eran el despacho.
    /// </summary>
    private static void Condiciones(IContainer contenedor, ComprobanteBase c)
    {
        var factura = c as Factura;

        var hayCargos = c.CargosGlobales.Count > 0;
        var hayCuotas = factura is not null && factura.Cuotas.Count > 0;
        var hayDetraccion = factura?.Detraccion is not null;

        // UN CONTENEDOR DE QuestPDF NECESITA EXACTAMENTE UN HIJO, siempre.
        // Devolver sin poner nada lanza "Container should contain exactly one
        // child", que es un error de la librería y no del documento. Un texto
        // vacío ocupa cero y cumple.
        if (!hayCargos && !hayCuotas && !hayDetraccion)
        {
            contenedor.Text("");
            return;
        }

        contenedor.Column(columna =>
        {
            columna.Spacing(6);

            // --- Qué son los cargos y descuentos globales --------------------

            if (hayCargos)
            {
                columna.Item().Column(caja =>
                {
                    caja.Item().Text("Cargos y descuentos")
                        .FontSize(8).SemiBold();

                    foreach (var cg in c.CargosGlobales)
                    {
                        // EL 49 YA ESTÁ DENTRO DEL VALOR DE VENTA, así que
                        // hay que decirlo: si no, el cliente lo suma otra
                        // vez y le sale de más.
                        var nota = CodigoCargoDescuento.AfectaLaBase(cg.Codigo)
                            ? "  (ya incluido en el valor de venta)"
                            : "";

                        caja.Item().Row(fila =>
                        {
                            fila.RelativeItem().Text(
                                (string.IsNullOrWhiteSpace(cg.Descripcion)
                                    ? CodigoCargoDescuento.Descripcion(cg.Codigo)
                                    : cg.Descripcion) + nota)
                                .FontSize(8);

                            fila.ConstantItem(105).AlignRight().Text(
                                (cg.EsCargo ? "" : "- ") +
                                $"{SimboloMoneda(c.Moneda)} {F2(cg.Monto)}")
                                .FontSize(8);
                        });
                    }
                });
            }

            // --- Las cuotas ---------------------------------------------------

            if (factura is not null && hayCuotas)
            {
                columna.Item().Column(caja =>
                {
                    caja.Item().Text(
                        $"Pago en {factura.Cuotas.Count} " +
                        (factura.Cuotas.Count == 1 ? "cuota" : "cuotas"))
                        .FontSize(8).SemiBold();

                    foreach (var cuota in factura.Cuotas.OrderBy(x => x.Numero))
                    {
                        caja.Item().Row(fila =>
                        {
                            fila.RelativeItem().Text(
                                $"Cuota {cuota.Numero} — vence el " +
                                cuota.FechaVencimiento.ToString("dd/MM/yyyy", Inv))
                                .FontSize(8);

                            fila.ConstantItem(105).AlignRight()
                                .Text($"{SimboloMoneda(c.Moneda)} {F2(cuota.Monto)}")
                                .FontSize(8);
                        });
                    }
                });
            }

            // --- La detracción --------------------------------------------------
            //
            // Lleva la cuenta del Banco de la Nación porque es donde el
            // cliente tiene que depositar. Sin ese número, la leyenda le dice
            // que debe detraer y no dónde.

            if (factura?.Detraccion is { } d)
            {
                columna.Item()
                    .Background(Colors.Grey.Lighten4).Padding(6)
                    .Column(caja =>
                    {
                        caja.Item().Text("Detracción (SPOT)").FontSize(8).SemiBold();

                        caja.Item().Text(
                            $"Bien o servicio {d.CodigoBienServicio} · " +
                            $"{d.Porcentaje.ToString("0.##", Inv)}% · " +
                            $"S/ {F2(d.Monto)}")
                            .FontSize(8);

                        caja.Item().Text(
                            $"Depositar en la cuenta del Banco de la Nación " +
                            $"N.° {d.CuentaBancoNacion}")
                            .FontSize(8);
                    });
            }
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

    /// <summary>
    /// Las etiquetas de los campos propios que ya sabemos cómo se llaman en
    /// castellano.
    ///
    /// Partir "ordenCompra" por sus mayúsculas da "Orden compra", que se lee
    /// mal en un documento que va a un cliente. Las preposiciones no se
    /// deducen de la clave: hay que saberlas.
    /// </summary>
    private static readonly Dictionary<string, string> EtiquetasExtra =
        new(StringComparer.OrdinalIgnoreCase)
        {
            ["ordenCompra"]    = "Orden de compra",
            ["ordenServicio"]  = "Orden de servicio",
            ["centroCosto"]    = "Centro de costo",
            ["guiaRemision"]   = "Guía de remisión",
            ["numeroContrato"] = "N.° de contrato",
            ["contrato"]       = "Contrato",
            ["vendedor"]       = "Vendedor",
            ["referencia"]     = "Referencia",
            ["observacion"]    = "Observación",
            ["observaciones"]  = "Observaciones"
        };

    /// <summary>
    /// Convierte la clave de un campo propio en algo legible.
    ///
    /// LA CLAVE LA ESCRIBE QUIEN INTEGRA, NO QUIEN LEE LA FACTURA. Imprimir
    /// "ordenCompra" tal cual en un documento que va a un cliente delata el
    /// nombre interno de un campo, y queda como un descuido.
    ///
    /// Si la clave no está en la tabla de arriba, se parte por sus mayúsculas
    /// y por los guiones. No sale perfecto siempre, pero sale legible, y una
    /// clave nueva no obliga a tocar este archivo.
    /// </summary>
    internal static string EtiquetaExtra(string clave)   // 22 oct: también el ticket
    {
        if (string.IsNullOrWhiteSpace(clave)) return "";

        if (EtiquetasExtra.TryGetValue(clave, out var conocida)) return conocida;

        var texto = new System.Text.StringBuilder();

        foreach (var c in clave)
        {
            if (c is '_' or '-')
            {
                texto.Append(' ');
            }
            else if (char.IsUpper(c) && texto.Length > 0)
            {
                texto.Append(' ');
                texto.Append(char.ToLowerInvariant(c));
            }
            else
            {
                texto.Append(c);
            }
        }

        var resultado = texto.ToString().Trim();

        return resultado.Length == 0
            ? ""
            : char.ToUpperInvariant(resultado[0]) + resultado.Substring(1);
    }

    internal static string NombreDocumento(string tipo) => tipo switch
    {
        TipoComprobante.Factura => "FACTURA ELECTRÓNICA",
        TipoComprobante.Boleta => "BOLETA DE VENTA ELECTRÓNICA",
        TipoComprobante.NotaCredito => "NOTA DE CRÉDITO ELECTRÓNICA",
        TipoComprobante.NotaDebito => "NOTA DE DÉBITO ELECTRÓNICA",
        _ => "COMPROBANTE ELECTRÓNICO"
    };

    internal static string NombreTipoDoc(string tipo) => tipo switch
    {
        TipoDocIdentidad.Ruc => "RUC",
        TipoDocIdentidad.Dni => "DNI",
        TipoDocIdentidad.Pasaporte => "Pasaporte",
        TipoDocIdentidad.Extranjeria => "C. Extranjería",
        _ => "Documento"
    };

    private static string NombreMoneda(string moneda) => moneda switch
    {
        "PEN" => "Soles",
        "USD" => "Dólares americanos",
        "EUR" => "Euros",
        _ => moneda
    };

    internal static string SimboloMoneda(string moneda) => moneda switch
    {
        "PEN" => "S/",
        "USD" => "US$",
        "EUR" => "€",
        _ => moneda
    };

    internal static string DescripcionMotivo(NotaCredito n) =>
        string.IsNullOrWhiteSpace(n.DescripcionMotivo)
            ? MotivoNotaCredito.Descripcion(n.CodigoMotivo)
            : n.DescripcionMotivo;
}