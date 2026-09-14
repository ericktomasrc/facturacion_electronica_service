using Npgsql;

namespace Facturacion.Persistencia;

/// <summary>
/// Una transacción abierta con el tenant ya declarado para Row Level Security.
///
/// TODO acceso a datos pasa por aquí. No hay forma de consultar la base sin
/// declarar de qué empresa se está hablando, y esa es la idea: el aislamiento
/// no puede depender de que alguien se acuerde de poner un WHERE.
///
/// Uso:
///
///     await using var sesion = await fabrica.AbrirAsync(tenantId);
///     // ... consultas con sesion.Conexion y sesion.Transaccion ...
///     await sesion.ConfirmarAsync();
///
/// Si no se llama a ConfirmarAsync, el Dispose deshace todo. Es deliberado:
/// olvidarse de confirmar debe perder el trabajo, no guardarlo a medias.
/// </summary>
public sealed class SesionTenant : IAsyncDisposable
{
    private bool _confirmada;

    public NpgsqlConnection Conexion { get; }
    public NpgsqlTransaction Transaccion { get; }
    public Guid TenantId { get; }

    internal SesionTenant(
        NpgsqlConnection conexion, NpgsqlTransaction transaccion, Guid tenantId)
    {
        Conexion = conexion;
        Transaccion = transaccion;
        TenantId = tenantId;
    }

    public async Task ConfirmarAsync(CancellationToken ct = default)
    {
        await Transaccion.CommitAsync(ct);
        _confirmada = true;
    }

    public async ValueTask DisposeAsync()
    {
        if (!_confirmada)
        {
            try { await Transaccion.RollbackAsync(); }
            catch (Exception) { /* la conexión ya pudo cerrarse */ }
        }

        await Transaccion.DisposeAsync();
        await Conexion.DisposeAsync();
    }
}

/// <summary>
/// Abre sesiones de base de datos con el contexto de tenant establecido.
/// </summary>
public sealed class FabricaSesiones
{
    private readonly string _cadenaConexion;

    public FabricaSesiones(string cadenaConexion)
    {
        if (string.IsNullOrWhiteSpace(cadenaConexion))
            throw new ArgumentException(
                "La cadena de conexión no puede estar vacía.", nameof(cadenaConexion));

        _cadenaConexion = cadenaConexion;
    }

    /// <summary>
    /// Abre una transacción y declara el tenant para las políticas de seguridad.
    /// </summary>
    public async Task<SesionTenant> AbrirAsync(
        Guid tenantId, CancellationToken ct = default)
    {
        if (tenantId == Guid.Empty)
            throw new ArgumentException(
                "El tenant no puede ser vacío. Sin tenant no se ve ninguna fila, " +
                "así que esto sería un error silencioso.", nameof(tenantId));

        var conexion = new NpgsqlConnection(_cadenaConexion);
        await conexion.OpenAsync(ct);

        NpgsqlTransaction transaccion;

        try
        {
            transaccion = await conexion.BeginTransactionAsync(ct);
        }
        catch
        {
            await conexion.DisposeAsync();
            throw;
        }

        try
        {
            // SET LOCAL, NO SET.
            //
            // Con LOCAL el valor muere al terminar la transacción. Sin él
            // quedaría pegado a la conexión física, y como las conexiones se
            // reutilizan desde el pool, la siguiente petición heredaría el
            // tenant de la anterior. Ese sería el peor fallo posible del
            // sistema: una empresa viendo datos de otra.
            //
            // SET LOCAL no admite parámetros, así que el valor se interpola.
            // Es seguro porque tenantId es un Guid tipado: no puede contener
            // nada que no sea un identificador válido.
            await using var comando = new NpgsqlCommand(
                $"SET LOCAL app.tenant_id = '{tenantId}'", conexion, transaccion);

            await comando.ExecuteNonQueryAsync(ct);
        }
        catch
        {
            await transaccion.DisposeAsync();
            await conexion.DisposeAsync();
            throw;
        }

        return new SesionTenant(conexion, transaccion, tenantId);
    }

    /// <summary>
    /// Abre una conexión SIN contexto de tenant.
    ///
    /// Solo para la tabla de tenants, que es el catálogo y no está sujeta a
    /// las políticas. Cualquier otro uso vería cero filas, porque las
    /// políticas fallan cerrado cuando no hay tenant declarado.
    /// </summary>
    public async Task<NpgsqlConnection> AbrirCatalogoAsync(CancellationToken ct = default)
    {
        var conexion = new NpgsqlConnection(_cadenaConexion);
        await conexion.OpenAsync(ct);
        return conexion;
    }
}
