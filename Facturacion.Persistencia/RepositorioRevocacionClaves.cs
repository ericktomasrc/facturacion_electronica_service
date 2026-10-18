using Dapper;
using Npgsql;

namespace Facturacion.Persistencia;

public enum ResultadoRevocacion { Revocada, EsLaUnica, NoEncontrada }

/// <summary>
/// La revocación de una clave fac_ por sí misma (punto 21). Con el rol de
/// operador, como el panel: la aplicación solo puede leer api_keys.
/// </summary>
public sealed class RepositorioRevocacionClaves
{
    private readonly string _cadenaOperador;

    public RepositorioRevocacionClaves(string cadenaConexionOperador)
    {
        _cadenaOperador = cadenaConexionOperador
            ?? throw new ArgumentNullException(nameof(cadenaConexionOperador));
    }

    public async Task<ResultadoRevocacion> RevocarAsync(Guid tenantId, string hash, CancellationToken ct = default)
    {
        await using var conexion = new NpgsqlConnection(_cadenaOperador);
        await conexion.OpenAsync(ct);
        await using var tx = await conexion.BeginTransactionAsync(ct);

        // Las claves de la empresa en fila: dos revocaciones a la vez no pueden
        // dejarla sin ninguna.
        await conexion.ExecuteAsync(new CommandDefinition(
            "SELECT pg_advisory_xact_lock(hashtextextended('claves:' || @tenantId::text, 0))",
            new { tenantId }, tx, cancellationToken: ct));

        var esta = await conexion.ExecuteScalarAsync<Guid?>(new CommandDefinition(
            "SELECT id FROM api_keys WHERE hash = @hash AND tenant_id = @tenantId AND activo",
            new { hash, tenantId }, tx, cancellationToken: ct));

        if (esta is null)
        {
            await tx.RollbackAsync(ct);
            return ResultadoRevocacion.NoEncontrada;
        }

        var otras = await conexion.ExecuteScalarAsync<int>(new CommandDefinition(
            "SELECT count(*)::int FROM api_keys WHERE tenant_id = @tenantId AND activo AND id <> @id",
            new { tenantId, id = esta }, tx, cancellationToken: ct));

        if (otras == 0)
        {
            await tx.RollbackAsync(ct);
            return ResultadoRevocacion.EsLaUnica;
        }

        await conexion.ExecuteAsync(new CommandDefinition(
            "UPDATE api_keys SET activo = false, revocado_en = now() WHERE id = @id AND activo",
            new { id = esta }, tx, cancellationToken: ct));

        await tx.CommitAsync(ct);
        return ResultadoRevocacion.Revocada;
    }
}