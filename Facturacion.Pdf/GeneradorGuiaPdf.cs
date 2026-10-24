using System.Globalization;
using Facturacion.Cpe;
using QuestPDF.Fluent;
using QuestPDF.Helpers;
using QuestPDF.Infrastructure;

namespace Facturacion.Pdf;

/// <summary>
/// 24 oct: la representación impresa de una guía de remisión (09 y 31).
///
/// ES LA HOJA QUE LLEVA EL CONDUCTOR. Por eso el orden es el de un control en
/// carretera: quién la emite y su número, de dónde sale y a dónde va, quién
/// lo lleva (placa, conductor, licencia), qué va dentro y cuánto pesa. Sin
/// importes: una guía no los tiene.
///
/// EL QR. Cuando SUNAT acepta una guía, su constancia trae un enlace de
/// consulta («descargaqr»). Ese es el QR que se imprime: un inspector lo lee
/// y ve la guía en SUNAT. Mientras no haya constancia no hay QR, y la hoja lo
/// dice en grande: sin «Aceptada», el vehículo no sale.
///
/// EL PDF NO ES LA GUÍA. La guía es el XML firmado y aceptado.
/// </summary>
public static class GeneradorGuiaPdf
{
    private static readonly CultureInfo Inv = CultureInfo.InvariantCulture;

    private static string Fecha(DateTime f) => f.ToString("dd/MM/yyyy", Inv);

    private static string Cantidad(decimal c) =>
        c == decimal.Truncate(c) ? c.ToString("N0", Inv) : c.ToString("N2", Inv);

    public static byte[] Generar(
        GuiaRemision g,
        string? enlaceQr,
        OpcionesImpresion? opciones = null)
    {
        GeneradorPdf.ConfigurarLicencia();
        opciones ??= OpcionesImpresion.PorDefecto;

        var imagenQr = string.IsNullOrWhiteSpace(enlaceQr)
            ? null
            : CodigoQr.GenerarPng(enlaceQr);

        var titulo = g.EsTransportista
            ? "GUÍA DE REMISIÓN ELECTRÓNICA TRANSPORTISTA"
            : "GUÍA DE REMISIÓN ELECTRÓNICA REMITENTE";

        var documento = Document.Create(contenedor =>
        {
            contenedor.Page(pagina =>
            {
                pagina.Size(PageSizes.A4);
                pagina.Margin(1.5f, Unit.Centimetre);
                pagina.DefaultTextStyle(x => x.FontSize(9));

                pagina.Header().Element(e => Encabezado(e, g, titulo, opciones));

                pagina.Content().PaddingVertical(12).Column(columna =>
                {
                    columna.Spacing(10);

                    columna.Item().Element(e => Traslado(e, g));
                    columna.Item().Element(e => Recorrido(e, g));
                    columna.Item().Element(e => Transporte(e, g));
                    columna.Item().Element(e => Bienes(e, g));

                    var docs = g.DocumentosRelacionados
                        .Where(d => !string.IsNullOrWhiteSpace(d.NumeroDocumento))
                        .ToList();

                    if (docs.Count > 0)
                    {
                        columna.Item().Text(t =>
                        {
                            t.Span("Documentos relacionados: ").SemiBold();
                            t.Span(string.Join("  ·  ", docs.Select(d =>
                                $"{NombreDocumento(d.TipoDocumento)} {d.NumeroDocumento}" +
                                (string.IsNullOrWhiteSpace(d.RucEmisor) || d.RucEmisor == g.Remitente.Ruc
                                    ? ""
                                    : $" (RUC {d.RucEmisor})"))));
                        });
                    }

                    if (!string.IsNullOrWhiteSpace(g.Observaciones))
                    {
                        columna.Item().Text(t =>
                        {
                            t.Span("Observaciones: ").SemiBold();
                            t.Span(g.Observaciones);
                        });
                    }
                });

                pagina.Footer().Element(e => Pie(e, imagenQr, opciones));
            });
        });

        return documento.GeneratePdf();
    }

    // ================================================================ bloques

    private static void Encabezado(
        IContainer contenedor, GuiaRemision g, string titulo, OpcionesImpresion opciones)
    {
        contenedor.Row(fila =>
        {
            fila.RelativeItem().Column(columna =>
            {
                if (opciones.Logo is not null)
                    columna.Item().Height(50).Image(opciones.Logo).FitHeight();

                columna.Item().Text(
                    string.IsNullOrWhiteSpace(g.Remitente.NombreComercial)
                        ? g.Remitente.RazonSocial
                        : g.Remitente.NombreComercial)
                    .FontSize(14).Bold();

                columna.Item().Text(g.Remitente.RazonSocial).FontSize(8);

                if (!string.IsNullOrWhiteSpace(g.Remitente.Direccion))
                    columna.Item().Text(g.Remitente.Direccion).FontSize(8);
            });

            fila.ConstantItem(20);

            fila.ConstantItem(210)
                .Border(1).BorderColor(Colors.Grey.Darken1)
                .Padding(8)
                .Column(columna =>
                {
                    columna.Spacing(3);
                    columna.Item().AlignCenter().Text($"R.U.C. {g.Remitente.Ruc}").FontSize(11).Bold();
                    columna.Item().AlignCenter().Text(titulo).FontSize(9).Bold();
                    columna.Item().AlignCenter().Text(g.Numero).FontSize(12).Bold();
                    columna.Item().AlignCenter().Text($"Emitida el {Fecha(g.FechaEmision)}").FontSize(8);
                });
        });
    }

    private static void Traslado(IContainer contenedor, GuiaRemision g)
    {
        contenedor.Background(Colors.Grey.Lighten4).Padding(8).Column(columna =>
        {
            columna.Spacing(3);

            columna.Item().Row(fila =>
            {
                fila.RelativeItem().Text(t =>
                {
                    t.Span("Inicio del traslado: ").SemiBold();
                    t.Span(Fecha(g.FechaTraslado));
                });

                fila.RelativeItem().Text(t =>
                {
                    t.Span("Motivo: ").SemiBold();
                    var motivo = CatalogosGre.MotivoTraslado.Descripciones
                        .TryGetValue(g.MotivoTraslado, out var d) ? d : g.MotivoTraslado;
                    t.Span(string.IsNullOrWhiteSpace(g.DescripcionMotivo)
                        ? motivo
                        : $"{motivo} ({g.DescripcionMotivo})");
                });
            });

            columna.Item().Row(fila =>
            {
                fila.RelativeItem().Text(t =>
                {
                    t.Span("Destinatario: ").SemiBold();
                    t.Span($"{g.Destinatario.RazonSocial} — {NombreIdentidad(g.Destinatario.TipoDocumento)} {g.Destinatario.NumeroDocumento}");
                });
            });

            if (g.EsTransportista && g.Contratante is not null)
            {
                columna.Item().Text(t =>
                {
                    t.Span("Remitente (quien contrató): ").SemiBold();
                    t.Span($"{g.Contratante.RazonSocial} — {NombreIdentidad(g.Contratante.TipoDocumento)} {g.Contratante.NumeroDocumento}");
                });
            }

            if (g.PagadorFlete is not null)
            {
                columna.Item().Text(t =>
                {
                    t.Span("Paga el flete: ").SemiBold();
                    t.Span($"{g.PagadorFlete.RazonSocial} — {g.PagadorFlete.NumeroDocumento}");
                });
            }
        });
    }

    private static void Recorrido(IContainer contenedor, GuiaRemision g)
    {
        contenedor.Row(fila =>
        {
            fila.RelativeItem().Border(0.5f).BorderColor(Colors.Grey.Lighten1).Padding(8).Column(c =>
            {
                c.Spacing(2);
                c.Item().Text("PUNTO DE PARTIDA").FontSize(7.5f).SemiBold().FontColor(Colors.Grey.Darken2);
                c.Item().Text(g.PuntoPartida.Direccion);
                c.Item().Text(Lugar(g.PuntoPartida)).FontSize(8).FontColor(Colors.Grey.Darken1);
            });

            fila.ConstantItem(10);

            fila.RelativeItem().Border(0.5f).BorderColor(Colors.Grey.Lighten1).Padding(8).Column(c =>
            {
                c.Spacing(2);
                c.Item().Text("PUNTO DE LLEGADA").FontSize(7.5f).SemiBold().FontColor(Colors.Grey.Darken2);
                c.Item().Text(g.PuntoLlegada.Direccion);
                c.Item().Text(Lugar(g.PuntoLlegada)).FontSize(8).FontColor(Colors.Grey.Darken1);
            });
        });
    }

    private static void Transporte(IContainer contenedor, GuiaRemision g)
    {
        var publico = g.ModalidadTraslado == CatalogosGre.ModalidadTraslado.Publico;

        contenedor.Border(0.5f).BorderColor(Colors.Grey.Lighten1).Padding(8).Column(c =>
        {
            c.Spacing(3);

            c.Item().Text(g.EsTransportista
                    ? "TRANSPORTE"
                    : publico ? "TRANSPORTE PÚBLICO (empresa de transporte)" : "TRANSPORTE PRIVADO")
                .FontSize(7.5f).SemiBold().FontColor(Colors.Grey.Darken2);

            if (publico && g.Transportista is not null)
            {
                c.Item().Text(t =>
                {
                    t.Span("Transportista: ").SemiBold();
                    t.Span($"{g.Transportista.RazonSocial} — RUC {g.Transportista.NumeroDocumento}");
                    if (!string.IsNullOrWhiteSpace(g.Transportista.NumeroMtc))
                        t.Span($" · MTC {g.Transportista.NumeroMtc}");
                });

                if (g.FechaEntregaAlTransportista is { } entrega)
                    c.Item().Text($"Entrega al transportista: {Fecha(entrega)}");
            }

            if (g.EsTransportista && !string.IsNullOrWhiteSpace(g.NumeroMtc))
                c.Item().Text($"Registro MTC: {g.NumeroMtc}");

            if (g.VehiculoMenor)
                c.Item().Text("Traslado en vehículo menor (M1 o L): no requiere placa ni conductor.");

            // 24 oct: transbordo programado, retorno vacío o con envases.
            var marcas = Marcas(g);
            if (marcas.Count > 0)
                c.Item().Text(t =>
                {
                    t.Span("Indicadores: ").SemiBold();
                    t.Span(string.Join(" · ", marcas));
                });

            if (g.Vehiculo is not null)
            {
                c.Item().Text(t =>
                {
                    t.Span("Vehículo: ").SemiBold();
                    t.Span($"placa {g.Vehiculo.Placa}");
                    if (!string.IsNullOrWhiteSpace(g.Vehiculo.Tuc))
                        t.Span($" · certificado {g.Vehiculo.Tuc}");
                    if (!string.IsNullOrWhiteSpace(g.Vehiculo.NumeroAutorizacion))
                        t.Span($" · autorización {g.Vehiculo.NumeroAutorizacion}");
                });
            }

            if (g.Conductor is not null)
                c.Item().Text(t => Conductor(t, "Conductor: ", g.Conductor));

            foreach (var relevo in g.ConductoresSecundarios)
                c.Item().Text(t => Conductor(t, "Conductor de relevo: ", relevo));

            if (g.OperadorSubcontratado is not null)
            {
                c.Item().Text(t =>
                {
                    t.Span("Subcontratado: ").SemiBold();
                    t.Span($"{g.OperadorSubcontratado.RazonSocial} — RUC {g.OperadorSubcontratado.NumeroDocumento}");
                });
            }
        });
    }

    private static void Conductor(TextDescriptor t, string etiqueta, Conductor c)
    {
        t.Span(etiqueta).SemiBold();
        t.Span($"{c.Nombres} {c.Apellidos} — {NombreIdentidad(c.TipoDocumento)} {c.NumeroDocumento} · licencia {c.Licencia}");
    }

    private static void Bienes(IContainer contenedor, GuiaRemision g)
    {
        contenedor.Column(columna =>
        {
            columna.Item().Table(t =>
            {
                t.ColumnsDefinition(c =>
                {
                    c.ConstantColumn(28);
                    c.ConstantColumn(70);
                    c.RelativeColumn();
                    c.ConstantColumn(70);
                    c.ConstantColumn(60);
                });

                t.Header(h =>
                {
                    Titulo(h, "N°");
                    Titulo(h, "Código");
                    Titulo(h, "Descripción");
                    Titulo(h, "Unidad");
                    Titulo(h, "Cantidad", derecha: true);
                });

                var n = 0;
                foreach (var b in g.Bienes)
                {
                    n++;
                    Celda(t, n.ToString(Inv));
                    Celda(t, b.CodigoProducto ?? "");
                    Celda(t, b.Descripcion);
                    Celda(t, NombreUnidad(b.UnidadMedida));
                    Celda(t, Cantidad(b.Cantidad), derecha: true);
                }
            });

            columna.Item().PaddingTop(6).AlignRight().Text(t =>
            {
                t.Span("Peso bruto total: ").SemiBold();
                t.Span($"{g.PesoBruto.ToString("N2", Inv)} {(g.UnidadPeso == "TNE" ? "t" : "kg")}");
                if (g.NumeroBultos is { } bultos)
                {
                    t.Span("   ·   Bultos: ").SemiBold();
                    t.Span(bultos.ToString(Inv));
                }
            });
        });
    }

    private static void Pie(IContainer contenedor, byte[]? qr, OpcionesImpresion opciones)
    {
        var aceptada = opciones.EstadoSunat is "ACEPTADO" or "ACEPTADO_CON_OBSERVACIONES";

        contenedor.PaddingTop(8).BorderTop(0.5f)
            .BorderColor(Colors.Grey.Lighten1).PaddingTop(8)
            .Row(fila =>
            {
                if (qr is not null)
                {
                    fila.ConstantItem(78).Height(78).Image(qr).FitArea();
                    fila.ConstantItem(12);
                }

                fila.RelativeItem().PaddingTop(4).Column(columna =>
                {
                    columna.Spacing(2);

                    columna.Item().Text("Representación impresa de la guía de remisión electrónica.")
                        .FontSize(7.5f);

                    if (qr is not null)
                    {
                        columna.Item().Text("Escanee el QR para verla en SUNAT.")
                            .FontSize(7.5f).FontColor(Colors.Grey.Darken1);
                    }

                    if (opciones.EstadoSunat == "ANULADO")
                    {
                        columna.Item().PaddingTop(3).Text("ANULADA — no sustenta ningún traslado.")
                            .FontSize(10).Bold().FontColor(Colors.Red.Darken2);
                    }
                    else if (!aceptada)
                    {
                        columna.Item().PaddingTop(3)
                            .Text("TODAVÍA NO ACEPTADA POR SUNAT — el vehículo no debe salir con esta hoja.")
                            .FontSize(10).Bold().FontColor(Colors.Red.Darken2);
                    }

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

    // ============================================================ auxiliares

    private static string Lugar(DireccionTraslado d)
    {
        var partes = new List<string>();
        if (!string.IsNullOrWhiteSpace(d.Ubigeo)) partes.Add($"Ubigeo {d.Ubigeo}");
        if (!string.IsNullOrWhiteSpace(d.CodigoEstablecimiento))
            partes.Add($"Establecimiento {d.CodigoEstablecimiento}");
        return string.Join(" · ", partes);
    }

    /// <summary>
    /// 24 oct: los indicadores que la hoja nombra. El del flete y el del
    /// vehículo menor ya se ven en otra parte.
    /// </summary>
    internal static List<string> Marcas(GuiaRemision g) => g.Indicadores
        .Where(i => i is IndicadorGre.TransbordoProgramado or IndicadorGre.RetornoVehiculoVacio
                     or IndicadorGre.RetornoVehiculoEnvaseVacio or IndicadorGre.TrasladoTotal
                     or IndicadorGre.TransporteSubcontratado)
        .Select(IndicadorGre.Nombre)
        .ToList();

    internal static string NombreIdentidad(string tipo) => tipo switch
    {
        "6" => "RUC",
        "1" => "DNI",
        "4" => "C.E.",
        "7" => "Pasaporte",
        "0" => "Doc.",
        _ => "Doc."
    };

    /// <summary>Catálogo 61, en palabras (24 oct: con los que ofrece la plataforma).</summary>
    internal static string NombreDocumento(string tipo) => tipo switch
    {
        "01" => "Factura",
        "03" => "Boleta",
        "04" => "Liquidación de compra",
        "09" => "Guía remitente",
        "12" => "Ticket",
        "31" => "Guía transportista",
        "48" => "Comprobante de operaciones Ley 29972",
        "49" => "Constancia de depósito IVAP",
        "50" => "DAM",
        "52" => "Declaración simplificada",
        "80" => "Constancia de depósito de detracción",
        "81" => "Código de autorización SCOP",
        "82" => "Declaración jurada de mudanza",
        _ => $"Doc. {tipo}"
    };

    /// <summary>Las unidades más frecuentes, en palabras (catálogo 03).</summary>
    public static string NombreUnidad(string codigo) => codigo switch
    {
        "NIU" => "Unidad",
        "ZZ" => "Servicio",
        "KGM" => "Kilogramo",
        "TNE" => "Tonelada",
        "GRM" => "Gramo",
        "LTR" => "Litro",
        "MTR" => "Metro",
        "MTK" => "Metro²",
        "MTQ" => "Metro³",
        "BX" => "Caja",
        "BG" => "Bolsa",
        "PK" => "Paquete",
        "DZN" => "Docena",
        "SET" => "Juego",
        "BLL" => "Barril",
        "GLL" => "Galón",
        "PR" => "Par",
        "RO" => "Rollo",
        "CY" => "Cilindro",
        "SA" => "Saco",
        "CJ" => "Caja",
        "BO" => "Botella",
        "CA" => "Lata",
        "PL" => "Balde",
        _ => codigo
    };

    private static void Titulo(TableCellDescriptor t, string texto, bool derecha = false)
    {
        var celda = t.Cell().Background(Colors.Grey.Lighten2).PaddingVertical(5).PaddingHorizontal(3);
        (derecha ? celda.AlignRight() : celda).Text(texto).SemiBold().FontSize(8);
    }

    private static void Celda(TableDescriptor t, string texto, bool derecha = false)
    {
        var celda = t.Cell().BorderBottom(0.5f).BorderColor(Colors.Grey.Lighten2).PaddingVertical(4).PaddingHorizontal(3);
        (derecha ? celda.AlignRight() : celda).Text(texto);
    }
}