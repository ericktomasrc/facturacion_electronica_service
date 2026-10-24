using System.Globalization;
using Facturacion.Cpe;
using QuestPDF.Fluent;
using QuestPDF.Helpers;
using QuestPDF.Infrastructure;

namespace Facturacion.Pdf;

/// <summary>
/// 24 OCT — LA GUÍA DE REMISIÓN EN FORMATO «CLÁSICO SUNAT» (A4).
///
/// Para las empresas que eligieron el formato clásico en sus facturas: la
/// hoja se parece a la que genera SOL (blanco y negro, recuadro del RUC,
/// bloques con título y la tabla de bienes con las columnas de SOL).
///
/// LO QUE NO SE COPIA DE SOL: su pie («generada en el Sistema de SUNAT»).
/// Esta guía la emite la empresa desde su sistema. El QR de la constancia
/// va arriba a la izquierda, como en SOL.
///
/// SI ALGO NO CABE (un logo muy ancho, un texto sin espacios), sale en el
/// formato moderno: una guía no se queda sin hoja por el diseño.
/// </summary>
public static class GeneradorGuiaPdfClasico
{
    private static readonly CultureInfo Inv = CultureInfo.InvariantCulture;
    private const float Letra = 8f;

    private static string Fecha(DateTime f) => f.ToString("dd/MM/yyyy", Inv);

    private static string Cantidad(decimal c) =>
        c == decimal.Truncate(c) ? c.ToString("0", Inv) : c.ToString("0.00########", Inv);

    public static byte[] Generar(GuiaRemision g, string? enlaceQr, OpcionesImpresion? opciones = null)
    {
        GeneradorPdf.ConfigurarLicencia();
        opciones ??= OpcionesImpresion.PorDefecto;

        try
        {
            return Dibujar(g, enlaceQr, opciones);
        }
        catch (QuestPDF.Drawing.Exceptions.DocumentLayoutException)
        {
            return GeneradorGuiaPdf.Generar(g, enlaceQr, opciones);
        }
    }

    private static byte[] Dibujar(GuiaRemision g, string? enlaceQr, OpcionesImpresion o)
    {
        var qr = string.IsNullOrWhiteSpace(enlaceQr) ? null : CodigoQr.GenerarPng(enlaceQr);

        return Document.Create(contenedor =>
        {
            contenedor.Page(pagina =>
            {
                pagina.Size(PageSizes.A4);
                pagina.Margin(1.2f, Unit.Centimetre);
                pagina.DefaultTextStyle(x => x.FontSize(Letra).FontColor(Colors.Black));

                pagina.Header().Element(e => Encabezado(e, g, qr, o));

                pagina.Content().PaddingVertical(8).Column(col =>
                {
                    col.Spacing(6);
                    col.Item().Element(e => DatosGenerales(e, g));
                    col.Item().Element(e => Puntos(e, g));
                    col.Item().Element(e => Partes(e, g));
                    col.Item().Element(e => Documentos(e, g));
                    col.Item().Element(e => Bienes(e, g));
                    col.Item().Element(e => DatosTraslado(e, g));

                    if (!string.IsNullOrWhiteSpace(g.Observaciones))
                        col.Item().Element(e => Bloque(e, "Observaciones", c => c.Item().Text(g.Observaciones!)));
                });

                pagina.Footer().Element(e => Pie(e, o));
            });
        }).GeneratePdf();
    }

    // ------------------------------------------------------------------ partes

    private static void Encabezado(IContainer contenedor, GuiaRemision g, byte[]? qr, OpcionesImpresion o)
    {
        contenedor.Border(1).BorderColor(Colors.Black).Padding(8).Row(fila =>
        {
            if (qr is not null)
            {
                fila.ConstantItem(70).Height(70).Image(qr).FitArea();
                fila.ConstantItem(10);
            }

            fila.RelativeItem().Column(col =>
            {
                col.Spacing(1);
                if (o.Logo is not null)
                    col.Item().Height(36).AlignLeft().Image(o.Logo).FitArea();

                var comercial = string.IsNullOrWhiteSpace(g.Remitente.NombreComercial)
                    ? g.Remitente.RazonSocial : g.Remitente.NombreComercial;
                col.Item().Text(comercial.ToUpperInvariant()).FontSize(10.5f).Bold();
                if (!string.Equals(comercial, g.Remitente.RazonSocial, StringComparison.OrdinalIgnoreCase))
                    col.Item().Text(g.Remitente.RazonSocial).FontSize(8.5f);
                if (!string.IsNullOrWhiteSpace(g.Remitente.Direccion))
                    col.Item().Text(g.Remitente.Direccion).FontSize(8.5f);
                var lugar = string.Join(" - ", new[] { g.Remitente.Departamento, g.Remitente.Provincia, g.Remitente.Distrito }
                    .Where(x => !string.IsNullOrWhiteSpace(x)));
                if (lugar.Length > 0)
                    col.Item().Text(lugar).FontSize(8.5f);
            });

            fila.ConstantItem(10);

            fila.ConstantItem(200).Border(1.5f).BorderColor(Colors.Black).Padding(8).Column(col =>
            {
                col.Spacing(3);
                col.Item().AlignCenter().Text(g.EsTransportista
                        ? "GUÍA DE REMISIÓN ELECTRÓNICA TRANSPORTISTA"
                        : "GUÍA DE REMISIÓN ELECTRÓNICA REMITENTE")
                    .FontSize(10).Bold();
                col.Item().AlignCenter().Text($"RUC N° {g.Remitente.Ruc}").FontSize(10.5f).Bold();
                col.Item().AlignCenter().Text($"N° {g.Numero}").FontSize(10.5f).Bold();
            });
        });
    }

    private static void DatosGenerales(IContainer contenedor, GuiaRemision g)
    {
        var motivo = CatalogosGre.MotivoTraslado.Descripciones.TryGetValue(g.MotivoTraslado, out var d)
            ? d : g.MotivoTraslado;
        if (!string.IsNullOrWhiteSpace(g.DescripcionMotivo) &&
            !string.Equals(g.DescripcionMotivo, motivo, StringComparison.OrdinalIgnoreCase))
            motivo = $"{motivo} - {g.DescripcionMotivo!.ToUpperInvariant()}";

        Pares(contenedor, [
            ("Fecha de emisión", Fecha(g.FechaEmision)),
            ("Fecha de inicio de traslado", Fecha(g.FechaTraslado)),
            ("Motivo de traslado", g.EsTransportista ? null : motivo),
            ("Modalidad de transporte", g.EsTransportista ? null
                : g.ModalidadTraslado == CatalogosGre.ModalidadTraslado.Publico ? "TRANSPORTE PÚBLICO" : "TRANSPORTE PRIVADO"),
            ($"Peso bruto total de la guía ({(g.UnidadPeso == "TNE" ? "TNE" : "KGM")})", g.PesoBruto.ToString("0.000", Inv)),
            ("Número de bultos", g.NumeroBultos?.ToString(Inv))
        ]);
    }

    private static void Puntos(IContainer contenedor, GuiaRemision g)
    {
        contenedor.Row(fila =>
        {
            fila.RelativeItem().Element(e => Bloque(e, "Punto de partida", c => Punto(c, g.PuntoPartida)));
            fila.ConstantItem(6);
            fila.RelativeItem().Element(e => Bloque(e, "Punto de llegada", c => Punto(c, g.PuntoLlegada)));
        });
    }

    private static void Punto(ColumnDescriptor c, DireccionTraslado d)
    {
        c.Item().Text(d.Direccion.ToUpperInvariant());
        c.Item().Text(t =>
        {
            t.Span("Ubigeo: ");
            t.Span(d.Ubigeo).SemiBold();
            if (!string.IsNullOrWhiteSpace(d.CodigoEstablecimiento))
            {
                t.Span("   Código de establecimiento: ");
                t.Span(d.CodigoEstablecimiento).SemiBold();
            }
        });
    }

    private static void Partes(IContainer contenedor, GuiaRemision g)
    {
        Bloque(contenedor, "Datos del destinatario", c =>
        {
            c.Item().Text(t =>
            {
                t.Span(g.Destinatario.RazonSocial.ToUpperInvariant()).SemiBold();
                t.Span($" - {GeneradorGuiaPdf.NombreIdentidad(g.Destinatario.TipoDocumento)} N° {g.Destinatario.NumeroDocumento}");
            });

            if (g.EsTransportista && g.Contratante is not null)
                c.Item().Text(t =>
                {
                    t.Span("Remitente: ");
                    t.Span(g.Contratante.RazonSocial.ToUpperInvariant()).SemiBold();
                    t.Span($" - {GeneradorGuiaPdf.NombreIdentidad(g.Contratante.TipoDocumento)} N° {g.Contratante.NumeroDocumento}");
                });

            if (g.PagadorFlete is not null)
                c.Item().Text(t =>
                {
                    t.Span("Pagador del flete: ");
                    t.Span(g.PagadorFlete.RazonSocial.ToUpperInvariant()).SemiBold();
                    t.Span($" - RUC N° {g.PagadorFlete.NumeroDocumento}");
                });
        });
    }

    private static void Documentos(IContainer contenedor, GuiaRemision g)
    {
        var docs = g.DocumentosRelacionados.Where(d => !string.IsNullOrWhiteSpace(d.NumeroDocumento)).ToList();
        if (docs.Count == 0)
        {
            contenedor.Text("");
            return;
        }

        Bloque(contenedor, "Documentos relacionados", c =>
        {
            foreach (var doc in docs)
                c.Item().Text(t =>
                {
                    t.Span(GeneradorGuiaPdf.NombreDocumento(doc.TipoDocumento).ToUpperInvariant() + ": ");
                    t.Span(doc.NumeroDocumento).SemiBold();
                    if (!string.IsNullOrWhiteSpace(doc.RucEmisor))
                        t.Span($"   RUC emisor: {doc.RucEmisor}");
                });
        });
    }

    private static void Bienes(IContainer contenedor, GuiaRemision g)
    {
        contenedor.Column(col =>
        {
            col.Item().Background(Colors.Grey.Lighten3).Border(1).BorderColor(Colors.Black)
                .PaddingVertical(3).PaddingHorizontal(5).Text("Bienes por transportar").Bold();

            col.Item().Border(1).BorderColor(Colors.Black).Table(t =>
            {
                t.ColumnsDefinition(c =>
                {
                    c.ConstantColumn(22);   // N°
                    c.ConstantColumn(40);   // bien normalizado
                    c.ConstantColumn(52);   // código del bien
                    c.ConstantColumn(56);   // código producto SUNAT
                    c.ConstantColumn(48);   // partida arancelaria
                    c.ConstantColumn(44);   // GTIN
                    c.RelativeColumn();     // descripción
                    c.ConstantColumn(48);   // unidad
                    c.ConstantColumn(48);   // cantidad
                });

                t.Header(h =>
                {
                    foreach (var titulo in new[] { "N°", "Bien normalizado", "Código de bien", "Código producto SUNAT",
                                                   "Partida arancelaria", "Código GTIN", "Descripción", "Unidad de medida", "Cantidad" })
                        h.Cell().BorderBottom(1).BorderColor(Colors.Black).Padding(3).AlignCenter()
                            .Text(titulo).FontSize(7).SemiBold();
                });

                var n = 0;
                foreach (var b in g.Bienes)
                {
                    n++;
                    Celda(t, n.ToString(Inv), centro: true);
                    Celda(t, string.IsNullOrWhiteSpace(b.CodigoSunat) ? "NO" : "SI", centro: true);
                    Celda(t, b.CodigoProducto ?? "");
                    Celda(t, b.CodigoSunat ?? "");
                    Celda(t, "");
                    Celda(t, "");
                    Celda(t, b.Descripcion.ToUpperInvariant());
                    Celda(t, GeneradorGuiaPdf.NombreUnidad(b.UnidadMedida).ToUpperInvariant(), centro: true);
                    Celda(t, Cantidad(b.Cantidad), derecha: true);
                }
            });
        });
    }

    private static void DatosTraslado(IContainer contenedor, GuiaRemision g)
    {
        var publico = !g.EsTransportista && g.ModalidadTraslado == CatalogosGre.ModalidadTraslado.Publico;

        Bloque(contenedor, "Datos del traslado", c =>
        {
            if (publico && g.Transportista is not null)
            {
                c.Item().Text(t =>
                {
                    t.Span("Transportista: ");
                    t.Span(g.Transportista.RazonSocial.ToUpperInvariant()).SemiBold();
                    t.Span($" - RUC N° {g.Transportista.NumeroDocumento}");
                    if (!string.IsNullOrWhiteSpace(g.Transportista.NumeroMtc))
                        t.Span($"   N° de registro MTC: {g.Transportista.NumeroMtc}");
                });
                c.Item().Text($"Fecha de entrega de bienes al transportista: {Fecha(g.FechaEntregaEfectiva)}");
            }

            if (g.EsTransportista && !string.IsNullOrWhiteSpace(g.NumeroMtc))
                c.Item().Text($"N° de registro MTC: {g.NumeroMtc}");

            // Los indicadores, como las casillas de SOL.
            var indicadores = new List<string>();
            if (g.VehiculoMenor) indicadores.Add(IndicadorGre.Nombre(IndicadorGre.VehiculoMenor));
            indicadores.AddRange(GeneradorGuiaPdf.Marcas(g));
            if (indicadores.Count > 0)
                c.Item().Text(t =>
                {
                    t.Span("Indicadores: ");
                    t.Span(string.Join(" · ", indicadores).ToUpperInvariant()).SemiBold();
                });

            if (g.Vehiculo is not null)
            {
                c.Item().PaddingTop(2).Text("Datos de los vehículos").SemiBold();
                c.Item().Text(t =>
                {
                    t.Span("Principal - placa N° ");
                    t.Span(g.Vehiculo.Placa).SemiBold();
                    if (!string.IsNullOrWhiteSpace(g.Vehiculo.Tuc))
                        t.Span($"   Certificado de habilitación: {g.Vehiculo.Tuc}");
                    if (!string.IsNullOrWhiteSpace(g.Vehiculo.NumeroAutorizacion))
                        t.Span($"   Autorización especial: {g.Vehiculo.NumeroAutorizacion}");
                });
            }

            if (g.Conductor is not null)
            {
                c.Item().PaddingTop(2).Text("Datos de los conductores").SemiBold();
                c.Item().Text(t => Conductor(t, "Principal", g.Conductor));
                foreach (var relevo in g.ConductoresSecundarios)
                    c.Item().Text(t => Conductor(t, "Secundario", relevo));
            }

            if (g.OperadorSubcontratado is not null)
                c.Item().Text(t =>
                {
                    t.Span("Transportista subcontratado: ");
                    t.Span(g.OperadorSubcontratado.RazonSocial.ToUpperInvariant()).SemiBold();
                    t.Span($" - RUC N° {g.OperadorSubcontratado.NumeroDocumento}");
                });
        });
    }

    private static void Conductor(TextDescriptor t, string cual, Conductor c)
    {
        t.Span($"{cual} - ");
        t.Span($"{c.Nombres} {c.Apellidos}".ToUpperInvariant()).SemiBold();
        t.Span($" - {GeneradorGuiaPdf.NombreIdentidad(c.TipoDocumento)} N° {c.NumeroDocumento}   Licencia N° {c.Licencia}");
    }

    private static void Pie(IContainer contenedor, OpcionesImpresion o)
    {
        var aceptada = o.EstadoSunat is "ACEPTADO" or "ACEPTADO_CON_OBSERVACIONES";

        contenedor.BorderTop(0.5f).BorderColor(Colors.Black).PaddingTop(5).Column(col =>
        {
            col.Spacing(2);
            col.Item().Text("Representación impresa de la guía de remisión electrónica.").FontSize(7.5f);

            if (o.EstadoSunat == "ANULADO")
                col.Item().Text("ANULADA — NO SUSTENTA NINGÚN TRASLADO.").FontSize(10).Bold();
            else if (!aceptada)
                col.Item().Text("TODAVÍA NO ACEPTADA POR SUNAT — EL VEHÍCULO NO DEBE SALIR CON ESTA HOJA.").FontSize(10).Bold();
        });
    }

    // ------------------------------------------------------------ auxiliares

    private static void Bloque(IContainer contenedor, string titulo, Action<ColumnDescriptor> contenido)
    {
        contenedor.Border(1).BorderColor(Colors.Black).Column(col =>
        {
            col.Item().Background(Colors.Grey.Lighten3).BorderBottom(1).BorderColor(Colors.Black)
                .PaddingVertical(3).PaddingHorizontal(5).Text(titulo).Bold();
            col.Item().Padding(5).Column(c =>
            {
                c.Spacing(2);
                contenido(c);
            });
        });
    }

    private static void Pares(IContainer contenedor, (string Etiqueta, string? Valor)[] pares)
    {
        var visibles = pares.Where(p => !string.IsNullOrWhiteSpace(p.Valor)).ToList();

        contenedor.Border(1).BorderColor(Colors.Black).Padding(5).Table(t =>
        {
            t.ColumnsDefinition(c =>
            {
                c.ConstantColumn(150);
                c.RelativeColumn();
                c.ConstantColumn(150);
                c.RelativeColumn();
            });

            foreach (var (etiqueta, valor) in visibles)
            {
                t.Cell().PaddingVertical(1).Text($"{etiqueta}:");
                t.Cell().PaddingVertical(1).Text(valor!).SemiBold();
            }

            // La tabla de cuatro columnas necesita filas completas.
            if (visibles.Count % 2 == 1)
            {
                t.Cell().Text("");
                t.Cell().Text("");
            }
        });
    }

    private static void Celda(TableDescriptor t, string texto, bool derecha = false, bool centro = false)
    {
        var celda = t.Cell().BorderBottom(0.5f).BorderColor(Colors.Grey.Medium).Padding(3);
        (derecha ? celda.AlignRight() : centro ? celda.AlignCenter() : celda).Text(texto).FontSize(7.5f);
    }
}