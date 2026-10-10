namespace Facturacion.Cpe;

/// <summary>
/// Calcula descuentos, IGV y totales. Sirve para factura, boleta y notas.
///
/// CÓMO SE TRATA EL DESCUENTO GLOBAL, Y POR QUÉ:
///
/// SUNAT exige que la base imponible declarada en el documento sea exactamente
/// la suma de los valores de venta de las líneas (validación 3277). Por eso el
/// descuento global NO se declara aparte: se reparte dentro de las líneas.
///
/// Cada línea combina su propio descuento con su parte del global en un único
/// factor efectivo, aplicado en cascada:
///
///     factor = 1 - (1 - descuentoLinea) x (1 - descuentoGlobal)
///
/// Con 10% de línea y 10% global, el factor no es 20% sino 19%: el global se
/// aplica sobre lo que quedó después del de línea, no sobre el bruto.
///
/// TRES REGLAS MÁS QUE HAY QUE RESPETAR SIEMPRE:
///
/// 1. Redondeo a 2 decimales con MidpointRounding.AwayFromZero. El redondeo
///    bancario que .NET trae por defecto produce diferencias de un céntimo.
///
/// 2. El total es la SUMA de los valores ya redondeados de cada línea,
///    no el redondeo de la suma sin redondear.
///
/// 3. El descuento va ANTES del IGV.
/// </summary>
public static class CalculadoraTotales
{
    public static decimal Redondear(decimal valor) =>
        Math.Round(valor, 2, MidpointRounding.AwayFromZero);

    /// <summary>
    /// Factor de descuento efectivo de una línea, combinando el suyo propio
    /// con el descuento global del comprobante.
    ///
    /// Se redondea a 5 decimales porque es el valor que viaja al XML en
    /// MultiplierFactorNumeric, y SUNAT recalcula Amount = Base x Factor.
    /// Si aquí se usara más precisión que la declarada, no cuadraría.
    /// </summary>
    public static decimal FactorDescuento(decimal porcentajeLinea, decimal porcentajeGlobal)
    {
        if (porcentajeLinea <= 0 && porcentajeGlobal <= 0) return 0m;

        var restanteLinea = 1m - porcentajeLinea / 100m;
        var restanteGlobal = 1m - porcentajeGlobal / 100m;

        return Math.Round(
            1m - restanteLinea * restanteGlobal, 5, MidpointRounding.AwayFromZero);
    }

    /// <param name="fechaEmision">
    /// Solo se usa para saber qué tasa de ICBPER regía ese día. En null se
    /// toma la de hoy, que es lo correcto para un comprobante que se está
    /// emitiendo ahora.
    /// </param>
    public static LineaCalculada CalcularLinea(
        LineaComprobante linea,
        decimal descuentoGlobalPorcentaje = 0m,
        DateTime? fechaEmision = null)
    {
        var valorBruto = Redondear(linea.Cantidad * linea.ValorUnitario);

        var factor = FactorDescuento(
            linea.DescuentoPorcentaje, descuentoGlobalPorcentaje);

        var descuento = factor > 0 ? Redondear(valorBruto * factor) : 0m;

        // Orden importante: primero el descuento, después el impuesto.
        var valorVenta = valorBruto - descuento;

        // --- ISC: EL ÚNICO IMPUESTO QUE VA ANTES DEL IGV ---------------------
        //
        // Todos los demás se calculan sobre el valor de venta y se suman al
        // final. El ISC no: se suma A LA BASE, y el IGV se calcula sobre el
        // resultado. Se paga impuesto sobre impuesto.
        //
        // La regla 3272 lo comprueba línea por línea: la base del tributo
        // 1000 tiene que ser el valor de venta MÁS el ISC de esa línea. Por
        // eso este cálculo va aquí arriba y no con el ICBPER.

        var isc = linea.TieneIsc
            ? Isc.Calcular(valorVenta, linea.TasaIsc)
            : 0m;

        var baseIgv = valorVenta + isc;

        // GeneraIgv devuelve false para la afectación 40, así que una línea
        // de exportación sale con impuesto 0 sin necesidad de un caso aparte.
        var igv = AfectacionIgv.GeneraIgv(linea.TipoAfectacionIgv)
            ? Redondear(baseIgv * linea.PorcentajeIgv / 100m)
            : 0m;

        // --- ICBPER: el impuesto de las bolsas de plástico -------------------
        //
        // No sale de una base imponible sino de contar bolsas, y la cantidad
        // de bolsas es la cantidad de la línea (regla 3236).

        var tasaIcbper = !linea.AfectoIcbper
            ? 0m
            : linea.IcbperUnitario
              ?? Icbper.TasaVigente(fechaEmision ?? RelojPeru.Hoy);

        var icbper = tasaIcbper > 0
            ? Icbper.Calcular(tasaIcbper, linea.Cantidad)
            : 0m;

        // EL PRECIO UNITARIO INCLUYE TODOS LOS TRIBUTOS DE LA LÍNEA, ICBPER
        // incluido. La regla 3270 lo recalcula como (valor de venta + monto
        // total de tributos del ítem) entre la cantidad, y el ICBPER es uno
        // de esos tributos: dejarlo fuera descuadra el precio declarado.
        var precioUnitarioConIgv = linea.Cantidad == 0
            ? 0m
            : Redondear((valorVenta + igv + icbper + isc) / linea.Cantidad);

        return new LineaCalculada(
            linea, factor, valorBruto, descuento, valorVenta, igv,
            precioUnitarioConIgv, icbper, tasaIcbper, isc);
    }

    public static IReadOnlyList<LineaCalculada> CalcularLineas(ComprobanteBase comprobante) =>
        comprobante.Lineas
            .Select(l => CalcularLinea(
                l, comprobante.DescuentoGlobalPorcentaje, comprobante.FechaEmision))
            .ToList();

    public static TotalesComprobante Calcular(ComprobanteBase comprobante)
    {
        var calculadas = CalcularLineas(comprobante);

        decimal gravado = 0, exonerado = 0, inafecto = 0, gratuito = 0, exportacion = 0;
        decimal descuentos = 0, igvLineas = 0, igvGratuito = 0, icbper = 0;
        decimal gravadoIvap = 0, impuestoIvap = 0;
        decimal isc = 0, baseIsc = 0, valorVentaGravado = 0;

        foreach (var c in calculadas)
        {
            var afectacion = c.Linea.TipoAfectacionIgv;

            descuentos += c.Descuento;

            // EL ICBPER SE SUMA ANTES DE MIRAR LA AFECTACIÓN, y por eso va
            // fuera del if de las gratuitas: una bolsa entregada gratis
            // sigue pagando el impuesto. Lo que grava es la bolsa, no la
            // venta.
            icbper += c.Icbper;

            // El ISC de las líneas gratuitas NO cuenta en el total: las
            // reglas 3296 y 3298 excluyen expresamente las líneas con
            // tributo 9996. Por eso esto va DESPUÉS del icbper y ANTES del
            // if, pero mirando la afectación.
            if (c.TieneIsc && !AfectacionIgv.EsGratuita(afectacion))
            {
                isc += c.Isc;
                baseIsc += c.ValorVenta;
            }

            if (AfectacionIgv.EsGratuita(afectacion))
            {
                // LAS GRATUITAS LLEVAN CONTABILIDAD APARTE, Y ENTERA.
                //
                // Su valor no entra en el valor de venta (regla 3277, que solo
                // suma los tributos 1000, 1016, 9995, 9997 y 9998) ni su IGV
                // en el total de impuestos (regla 3294, que suma 1000, 1016,
                // 2000, 7152 y 9999). El 9996 no aparece en ninguna de las dos
                // listas, así que las gratuitas no alteran lo que se cobra.
                //
                // Pero el documento SÍ tiene que declarar los dos números en
                // su propio subtotal 9996: cuánto valía lo entregado (regla
                // 3276) y cuánto IGV generó (regla 3302). Por eso se acumulan
                // aquí en vez de descartarse.
                gratuito += c.ValorVenta;
                igvGratuito += c.Igv;
                continue;
            }

            switch (afectacion)
            {
                case AfectacionIgv.GravadoOperacionOnerosa:

                    // DOS NÚMEROS DISTINTOS, Y CON ISC DEJAN DE COINCIDIR:
                    //
                    //   gravado           → la BASE DEL IGV, que incluye el ISC
                    //   valorVentaGravado → el valor de venta, que no
                    //
                    // El primero va al subtotal del tributo 1000; el segundo
                    // al LineExtensionAmount del documento, que según la
                    // regla 3278 no suma el tributo 2000.
                    gravado += c.BaseIgv;
                    valorVentaGravado += c.ValorVenta;
                    igvLineas += c.Igv;
                    break;

                // EL ARROZ PILADO TIENE SU PROPIO CUBO Y SU PROPIO IMPUESTO.
                //
                // No suma en 'gravado' ni su impuesto en 'igvLineas': son
                // el tributo 1016 y no el 1000, y mezclarlos haria que el
                // documento declarase IGV donde no lo hay. Es el mismo error
                // que tuvo la exportacion en su dia.
                case AfectacionIgv.GravadoIvap:
                    gravadoIvap += c.ValorVenta;
                    impuestoIvap += c.Igv;
                    break;

                // LA EXPORTACIÓN TIENE SU PROPIO CUBO, NO EL DEL GRAVADO.
                //
                // Su IGV es cero, así que al sumarla con el gravado el importe
                // total salía bien y el error pasaba desapercibido — pero el
                // XML declaraba la base como gravada con tributo 1000, y SUNAT
                // rechaza eso con el error 3107.
                case AfectacionIgv.Exportacion:
                    exportacion += c.ValorVenta;
                    break;

                case AfectacionIgv.Exonerado:
                    exonerado += c.ValorVenta;
                    break;

                case AfectacionIgv.Inafecto:
                    inafecto += c.ValorVenta;
                    break;

                default:
                    throw new InvalidOperationException(
                        $"Afectación no contemplada en el cálculo: {afectacion}");
            }
        }

        gravado     = Redondear(gravado);
        exonerado   = Redondear(exonerado);
        inafecto    = Redondear(inafecto);
        exportacion = Redondear(exportacion);
        igvLineas   = Redondear(igvLineas);
        icbper      = Redondear(icbper);
        gravadoIvap  = Redondear(gravadoIvap);
        impuestoIvap = Redondear(impuestoIvap);
        isc          = Redondear(isc);
        baseIsc      = Redondear(baseIsc);
        valorVentaGravado = Redondear(valorVentaGravado);

        // --- El cargo global que SÍ afecta la base imponible (código 49) -----
        //
        // Es el único cargo del documento que no se limita a sumar al total:
        // se suma A LA BASE, y por tanto genera su propio impuesto. Las
        // reglas 3278 y 3279 lo dicen para el IGV, y las 3293 y 3295 para el
        // IVAP: base = suma de líneas - descuento 02 + CARGO 49.
        //
        // NO SE REPARTE ENTRE LAS LÍNEAS, al revés que el descuento global.
        // Viaja en su propio bloque y SUNAT lo suma por fuera. Por eso aquí
        // se trata aparte en vez de tocar el bucle de arriba.

        var cargoAfectaBase = Redondear(comprobante.CargosGlobales
            .Where(cg => CodigoCargoDescuento.AfectaLaBase(cg.Codigo))
            .Sum(cg => cg.Monto));

        if (cargoAfectaBase > 0)
        {
            if (gravadoIvap > 0)
            {
                gravadoIvap = Redondear(gravadoIvap + cargoAfectaBase);
                impuestoIvap = Redondear(
                    impuestoIvap + cargoAfectaBase * Ivap.Tasa / 100m);
            }
            else
            {
                // La tasa sale de las propias líneas gravadas, no de una
                // constante: la regla 3462 obliga a que todas tengan la
                // misma, así que la primera vale por todas. Leerla de ahí
                // evita que un cambio de tasa deje este punto desfasado.
                var tasa = comprobante.Lineas
                    .Where(l => l.TipoAfectacionIgv ==
                                AfectacionIgv.GravadoOperacionOnerosa)
                    .Select(l => l.PorcentajeIgv)
                    .DefaultIfEmpty(18m)
                    .First();

                gravado = Redondear(gravado + cargoAfectaBase);
                igvLineas = Redondear(igvLineas + cargoAfectaBase * tasa / 100m);

                // Y también al valor de venta: la regla 3278 suma el cargo
                // 49 al LineExtensionAmount, igual que la 3279 lo suma a la
                // base del IGV. Tiene que ser aquí y no más abajo, porque el
                // valor de venta se calcula justo después.
                valorVentaGravado = Redondear(valorVentaGravado + cargoAfectaBase);
            }
        }

        // La exportación SÍ entra en el valor de venta del comprobante.
        //
        // La regla 3278 dice que LineExtensionAmount es la suma de las líneas
        // con tributo 1000, 1016, 9995, 9997 y 9998. El 9995 está en esa
        // lista: dejarlo fuera haría que el total no cuadre con las líneas.
        //
        // Y OJO: los anticipos NO se restan de aquí. La regla 3277 solo resta
        // el descuento global código 02, no los códigos 04, 05 ni 06. El
        // valor de venta declara la operación completa.
        // El IVAP entra igual que el resto: la regla 3278 lista el 1016
        // junto al 1000, 9995, 9997 y 9998.
        //
        // valorVentaGravado y NO gravado: el LineExtensionAmount del
        // documento suma los tributos 1000, 1016, 9995, 9997 y 9998
        // (regla 3278). El 2000 no está en esa lista, así que el ISC sube la
        // base imponible pero no el valor de venta.
        var valorVenta = Redondear(
            valorVentaGravado + gravadoIvap + exonerado + inafecto + exportacion);

        // Precio de venta: la operación completa con todos sus tributos.
        // Regla 419, que tampoco resta anticipos.
        //
        // EL ICBPER ENTRA AQUÍ. La regla 3279 lo dice literalmente: el
        // TaxInclusiveAmount es el valor de venta más el ISC, más otros
        // tributos, más la sumatoria ICBPER, más el IGV. Es el único de los
        // añadidos recientes que sube el precio de venta — las gratuitas y
        // la percepción se quedan fuera.
        var precioVenta = Redondear(
            valorVenta + igvLineas + impuestoIvap + icbper + isc);

        // --- Anticipos -------------------------------------------------------

        var anticipoGravado = 0m;
        var anticipoExonerado = 0m;
        var anticipoInafecto = 0m;
        var totalAnticipos = 0m;
        var igvAnticipos = 0m;

        foreach (var a in comprobante.Anticipos)
        {
            totalAnticipos += a.MontoTotal;

            switch (a.TipoAfectacion)
            {
                case AfectacionIgv.GravadoOperacionOnerosa:
                    anticipoGravado += a.ValorVenta;

                    // El IGV que ya se pagó en la factura del anticipo.
                    // Es la diferencia entre lo cobrado y su valor de venta,
                    // no un recálculo: así cuadra con aquel comprobante
                    // exactamente, sin arrastrar un céntimo de desfase.
                    igvAnticipos += a.MontoTotal - a.ValorVenta;
                    break;

                case AfectacionIgv.Exonerado:
                    anticipoExonerado += a.ValorVenta;
                    break;

                case AfectacionIgv.Inafecto:
                    anticipoInafecto += a.ValorVenta;
                    break;

                default:
                    throw new InvalidOperationException(
                        $"Un anticipo no puede tener la afectación {a.TipoAfectacion}.");
            }
        }

        anticipoGravado   = Redondear(anticipoGravado);
        anticipoExonerado = Redondear(anticipoExonerado);
        anticipoInafecto  = Redondear(anticipoInafecto);
        totalAnticipos    = Redondear(totalAnticipos);
        igvAnticipos      = Redondear(igvAnticipos);

        // LAS BASES IMPONIBLES SÍ RESTAN EL ANTICIPO.
        //
        // Reglas 346 y 350: el TaxableAmount del tributo 1000 descuenta los
        // códigos 02 y 04, y el TaxAmount se calcula sobre esa base ya neta.
        // El IGV del anticipo se pagó en su momento; declararlo otra vez
        // sería cobrarlo dos veces.
        var baseGravada   = Redondear(gravado - anticipoGravado);
        var baseExonerada = Redondear(exonerado - anticipoExonerado);
        var baseInafecta  = Redondear(inafecto - anticipoInafecto);

        var igvDeclarado = Redondear(igvLineas - igvAnticipos);

        // --- Cargos y descuentos globales que no afectan la base -------------
        //
        // No tocan nada de lo anterior: ni el valor de venta, ni el IGV, ni
        // el precio de venta. Entran solo en el importe a pagar.
        //
        // Se agrupan en dos sumas porque SUNAT los pide así: los cargos en
        // cbc:ChargeTotalAmount (regla 3301) y los descuentos en
        // cbc:AllowanceTotalAmount (regla 3300). Cada código pertenece a una
        // de las dos listas, y CodigoCargoDescuento es quien lo sabe.

        var otrosCargos = 0m;
        var otrosDescuentos = 0m;

        foreach (var cg in comprobante.CargosGlobales)
        {
            // EL CÓDIGO 49 NO ENTRA AQUÍ, y es importante: ya se sumó a la
            // base imponible más arriba, y por tanto ya está dentro del
            // valor de venta y del precio de venta. Contarlo otra vez en
            // ChargeTotalAmount lo cobraría dos veces.
            if (CodigoCargoDescuento.AfectaLaBase(cg.Codigo))
                continue;

            if (CodigoCargoDescuento.SumaEnOtrosCargos(cg.Codigo))
                otrosCargos += cg.Monto;

            else if (CodigoCargoDescuento.SumaEnOtrosDescuentos(cg.Codigo))
                otrosDescuentos += cg.Monto;

            // Un código fuera de las dos listas no se suma en ningún sitio.
            // No se lanza excepción aquí a propósito: ReglasCargosGlobales
            // lo rechaza antes con un mensaje que explica qué poner, y esta
            // función también la llaman las propias reglas para calcular.
        }

        otrosCargos     = Redondear(otrosCargos);
        otrosDescuentos = Redondear(otrosDescuentos);

        // Importe a pagar: la operación completa, más los cargos que no
        // afectan la base, menos esos descuentos, menos lo ya adelantado.
        // Reglas 411 y 3280.
        var importeTotal = Redondear(
            precioVenta + otrosCargos - otrosDescuentos - totalAnticipos);

        return new TotalesComprobante(
            TotalGravado:      baseGravada,
            TotalExonerado:    baseExonerada,
            TotalInafecto:     baseInafecta,
            TotalGratuito:     Redondear(gratuito),
            TotalDescuentos:   Redondear(descuentos),
            TotalIgv:          igvDeclarado,
            ValorVenta:        valorVenta,
            ImporteTotal:      importeTotal,
            TotalExportacion:  exportacion,
            TotalAnticipos:    totalAnticipos,
            AnticipoGravado:   anticipoGravado,
            AnticipoExonerado: anticipoExonerado,
            AnticipoInafecto:  anticipoInafecto,
            PrecioVenta:       precioVenta,
            IgvGratuito:       Redondear(igvGratuito),
            TotalOtrosCargos:      otrosCargos,
            TotalOtrosDescuentos:  otrosDescuentos,
            TotalIcbper:           icbper,
            TotalGravadoIvap:      gravadoIvap,
            TotalIvap:             impuestoIvap,
            TotalIsc:              isc,
            TotalBaseIsc:          baseIsc,
            ValorVentaGravado:     valorVentaGravado);
    }
}
