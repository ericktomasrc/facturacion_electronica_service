using Dapper;
using Npgsql;

namespace Facturacion.Persistencia;

/// <summary>Gravedad general del sistema.</summary>
public enum NivelSalud
{
    Sano,
    Atencion,
    Problema
}

/// <summary>Un código de error que se está repitiendo.</summary>
public record ErrorFrecuente(
    string? CodigoSunat,
    string Mensaje,
    int Veces,
    DateTime UltimaVez);

/// <summary>Certificado que necesita atención.</summary>
public record CertificadoEnRiesgo(
    string Ruc,
    string RazonSocial,
    string Subject,
    DateTime ValidoHasta,
    int DiasRestantes)
{
    public bool YaVencio => DiasRestantes < 0;
}

/// <summary>Comprobante que lleva demasiado tiempo sin resolverse.</summary>
public record ComprobanteAtascado(
    Guid Id,
    string Ruc,
    string Numero,
    string Estado,
    short IntentosFallidos,
    string? UltimoMensaje,
    DateTime CreadoEn,
    DateTime? ProximoIntentoEn);

/// <summary>
/// Foto del estado del sistema en un momento dado.
/// </summary>
public record SaludSistema(
    NivelSalud Nivel,
    IReadOnlyList<string> Alertas,
    int Pendientes,
    int EnCola,
    int ConFallos,
    int AgotaronIntentos,
    int AceptadosHoy,
    int RechazadosHoy,
    DateTime? UltimoEnvioExitoso,
    int? MinutosDesdeUltimoExito,
    IReadOnlyList<ErrorFrecuente> ErroresFrecuentes,
    IReadOnlyList<CertificadoEnRiesgo> Certificados,
    IReadOnlyList<ComprobanteAtascado> Atascados)
{
    public double TasaExitoHoy =>
        AceptadosHoy + RechazadosHoy == 0
            ? 1.0
            : (double)AceptadosHoy / (AceptadosHoy + RechazadosHoy);
}

/// <summary>
/// Responde una sola pregunta: ¿está sano el sistema?
///
/// POR QUÉ EXISTE:
///
/// Hasta ahora, cuando algo fallaba quedaba registrado en la bitácora, pero
/// nadie se enteraba. Si mañana cuarenta comprobantes se atascan, el aviso
/// llegaría por la llamada de un cliente molesto.
///
/// Un sistema que registra errores pero no los muestra es un sistema que
/// falla en silencio. Esto cierra ese hueco.
///
/// Usa el rol de operador porque mira TODAS las empresas: es una vista de
/// infraestructura, no de cliente. El endpoint que la expone está protegido
/// aparte, con una clave distinta a las de los emisores.
/// </summary>
public sealed class RepositorioDiagnostico
{
    private readonly string _cadenaOperador;

    public RepositorioDiagnostico(string cadenaConexionOperador)
    {
        _cadenaOperador = cadenaConexionOperador
            ?? throw new ArgumentNullException(nameof(cadenaConexionOperador));
    }

    public async Task<SaludSistema> RevisarAsync(CancellationToken ct = default)
    {
        await using var conexion = new NpgsqlConnection(_cadenaOperador);
        await conexion.OpenAsync(ct);

        var contadores = await conexion.QuerySingleAsync<Contadores>(
            new CommandDefinition(
                """
                -- El ::int de cada contador no es decorativo.
                --
                -- count(*) en PostgreSQL devuelve bigint, que en C# es long.
                -- Si el record los declara como int, Dapper no encuentra un
                -- constructor que encaje y falla al materializar, con un
                -- mensaje que habla de constructores y no de tipos numéricos.
                --
                -- Convertir aquí es más claro que cambiar el record: estos
                -- contadores nunca van a superar los dos mil millones.
                SELECT
                    count(*) FILTER (
                        WHERE estado IN ('BORRADOR','ENCOLADO')
                    )::int AS "Pendientes",

                    count(*) FILTER (
                        WHERE estado = 'ENCOLADO'
                    )::int AS "EnCola",

                    -- En espera tras haber fallado al menos una vez.
                    count(*) FILTER (
                        WHERE estado = 'BORRADOR' AND intentos_fallidos > 0
                    )::int AS "ConFallos",

                    -- Rechazados tras agotar los reintentos: estos ya no se
                    -- van a resolver solos y necesitan que alguien mire.
                    count(*) FILTER (
                        WHERE estado = 'RECHAZADO' AND intentos_fallidos >= 8
                    )::int AS "AgotaronIntentos",

                    count(*) FILTER (
                        WHERE estado IN ('ACEPTADO','ACEPTADO_CON_OBSERVACIONES')
                          AND actualizado_en >= current_date
                    )::int AS "AceptadosHoy",

                    count(*) FILTER (
                        WHERE estado = 'RECHAZADO'
                          AND actualizado_en >= current_date
                    )::int AS "RechazadosHoy"
                FROM comprobantes
                """,
                cancellationToken: ct));

        // Cuándo fue la última vez que SUNAT aceptó algo.
        //
        // ES EL INDICADOR MÁS ÚTIL DE TODOS: si hay comprobantes esperando y
        // hace horas que no se acepta ninguno, algo está roto aunque no haya
        // ningún error visible. Los sistemas que se cuelgan en silencio no
        // producen errores, producen silencio.
        var ultimoExito = await conexion.ExecuteScalarAsync<DateTime?>(
            new CommandDefinition(
                """
                SELECT max(creado_en)
                  FROM envio_intentos
                 WHERE estado_nuevo IN ('ACEPTADO','ACEPTADO_CON_OBSERVACIONES')
                """,
                cancellationToken: ct));

        var errores = (await conexion.QueryAsync<ErrorFrecuente>(
            new CommandDefinition(
                """
                SELECT codigo_sunat   AS "CodigoSunat",
                       min(mensaje)   AS "Mensaje",
                       count(*)::int  AS "Veces",
                       max(creado_en) AS "UltimaVez"
                  FROM envio_intentos
                 WHERE estado_nuevo IN ('RECHAZADO','BORRADOR')
                   AND codigo_sunat IS NOT NULL
                   AND codigo_sunat <> '0'
                   AND creado_en >= now() - interval '24 hours'
                 GROUP BY codigo_sunat
                 ORDER BY count(*) DESC
                 LIMIT 10
                """,
                cancellationToken: ct))).ToList();

        var certificados = (await conexion.QueryAsync<CertificadoEnRiesgo>(
            new CommandDefinition(
                """
                SELECT t.ruc          AS "Ruc",
                       t.razon_social AS "RazonSocial",
                       c.subject      AS "Subject",
                       c.valido_hasta AS "ValidoHasta",
                       EXTRACT(DAY FROM (c.valido_hasta - now()))::int AS "DiasRestantes"
                  FROM certificados c
                  JOIN tenants t ON t.id = c.tenant_id
                 WHERE c.activo
                   AND c.valido_hasta < now() + interval '60 days'
                 ORDER BY c.valido_hasta
                """,
                cancellationToken: ct))).ToList();

        var atascados = (await conexion.QueryAsync<ComprobanteAtascado>(
            new CommandDefinition(
                """
                SELECT c.id                AS "Id",
                       t.ruc               AS "Ruc",
                       c.serie || '-' || lpad(c.correlativo::text, 8, '0') AS "Numero",
                       c.estado            AS "Estado",
                       c.intentos_fallidos AS "IntentosFallidos",
                       c.mensaje_sunat     AS "UltimoMensaje",
                       c.creado_en         AS "CreadoEn",
                       c.proximo_intento_en AS "ProximoIntentoEn"
                  FROM comprobantes c
                  JOIN tenants t ON t.id = c.tenant_id
                 WHERE c.intentos_fallidos > 0
                   AND c.estado IN ('BORRADOR','ENCOLADO','RECHAZADO')
                 ORDER BY c.intentos_fallidos DESC, c.creado_en
                 LIMIT 20
                """,
                cancellationToken: ct))).ToList();

        var minutosDesdeExito = ultimoExito is null
            ? (int?)null
            : (int)(DateTime.UtcNow - ultimoExito.Value.ToUniversalTime()).TotalMinutes;

        var (nivel, alertas) = Evaluar(
            contadores, certificados, minutosDesdeExito);

        return new SaludSistema(
            nivel, alertas,
            contadores.Pendientes, contadores.EnCola, contadores.ConFallos,
            contadores.AgotaronIntentos,
            contadores.AceptadosHoy, contadores.RechazadosHoy,
            ultimoExito, minutosDesdeExito,
            errores, certificados, atascados);
    }

    /// <summary>
    /// Traduce los números a un semáforo y a frases que se entienden sin
    /// conocer el sistema por dentro.
    ///
    /// Un panel lleno de cifras obliga a interpretarlas cada vez. Uno que
    /// dice "hay 12 comprobantes atascados desde hace 3 horas" se entiende
    /// a las tres de la mañana y medio dormido, que es cuando hace falta.
    /// </summary>
    private static (NivelSalud, List<string>) Evaluar(
        Contadores c,
        IReadOnlyList<CertificadoEnRiesgo> certificados,
        int? minutosDesdeExito)
    {
        var alertas = new List<string>();
        var nivel = NivelSalud.Sano;

        void Subir(NivelSalud propuesto)
        {
            if (propuesto > nivel) nivel = propuesto;
        }

        // Certificado vencido: la facturación de ese cliente está detenida.
        foreach (var cert in certificados.Where(x => x.YaVencio))
        {
            alertas.Add(
                $"El certificado de {cert.RazonSocial} ({cert.Ruc}) VENCIÓ el " +
                $"{cert.ValidoHasta:yyyy-MM-dd}. Esa empresa no puede facturar.");

            Subir(NivelSalud.Problema);
        }

        foreach (var cert in certificados.Where(x => !x.YaVencio && x.DiasRestantes <= 30))
        {
            alertas.Add(
                $"El certificado de {cert.RazonSocial} vence en {cert.DiasRestantes} días. " +
                "Renovarlo toma días, no horas.");

            Subir(NivelSalud.Atencion);
        }

        // Comprobantes que ya no se van a resolver solos.
        if (c.AgotaronIntentos > 0)
        {
            alertas.Add(
                $"{c.AgotaronIntentos} comprobante(s) agotaron sus reintentos. " +
                "Necesitan revisión manual: no van a salir solos.");

            Subir(NivelSalud.Problema);
        }

        // Hay trabajo esperando y hace rato que nada se acepta.
        if (c.Pendientes > 0 && minutosDesdeExito > 30)
        {
            alertas.Add(
                $"Hay {c.Pendientes} comprobante(s) pendientes y no se acepta " +
                $"ninguno desde hace {minutosDesdeExito} minutos. " +
                "Revisa si el worker está corriendo y si SUNAT responde.");

            Subir(NivelSalud.Problema);
        }
        else if (c.Pendientes > 100)
        {
            alertas.Add(
                $"La cola tiene {c.Pendientes} comprobantes. " +
                "Si sigue creciendo, hacen falta más workers.");

            Subir(NivelSalud.Atencion);
        }

        if (c.ConFallos > 0)
        {
            alertas.Add(
                $"{c.ConFallos} comprobante(s) fallaron y están esperando su " +
                "siguiente intento. Si el número no baja, mira los errores.");

            Subir(NivelSalud.Atencion);
        }

        // Muchos rechazos hoy suele significar un error en los datos que
        // entran, no un problema de SUNAT.
        var total = c.AceptadosHoy + c.RechazadosHoy;

        if (total >= 10 && c.RechazadosHoy > total * 0.2)
        {
            alertas.Add(
                $"Hoy se rechazó el {100.0 * c.RechazadosHoy / total:N0}% de los " +
                "comprobantes. Una tasa así suele venir de los datos que entran, " +
                "no de SUNAT.");

            Subir(NivelSalud.Atencion);
        }

        if (alertas.Count == 0)
            alertas.Add("Todo en orden.");

        return (nivel, alertas);
    }

    /// <summary>
    /// Devuelve un comprobante a la cola para volver a intentarlo.
    ///
    /// Es la salida para los que agotaron reintentos: se corrige la causa
    /// (se carga el certificado que faltaba, se restablece el servicio) y se
    /// reprocesa desde el panel, sin tocar la base a mano.
    ///
    /// NO sirve para los rechazados por datos: esos necesitan un comprobante
    /// nuevo, porque el XML está mal y reenviarlo daría el mismo resultado.
    /// </summary>
    public async Task<bool> ReprocesarAsync(
        Guid comprobanteId, CancellationToken ct = default)
    {
        await using var conexion = new NpgsqlConnection(_cadenaOperador);
        await conexion.OpenAsync(ct);

        var filas = await conexion.ExecuteAsync(new CommandDefinition(
            """
            UPDATE comprobantes
               SET estado = 'BORRADOR',
                   intentos_fallidos = 0,
                   proximo_intento_en = NULL
             WHERE id = @comprobanteId
               AND estado IN ('RECHAZADO','BORRADOR','ENCOLADO')
            """,
            new { comprobanteId }, cancellationToken: ct));

        return filas > 0;
    }

    private record Contadores(
        int Pendientes,
        int EnCola,
        int ConFallos,
        int AgotaronIntentos,
        int AceptadosHoy,
        int RechazadosHoy);
}
