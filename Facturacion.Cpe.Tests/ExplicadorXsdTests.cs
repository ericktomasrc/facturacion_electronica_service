using Facturacion.Cpe;

namespace Facturacion.Tests;

/// <summary>
/// Los errores del validador XSD de .NET, en castellano (migración 033). Los
/// mensajes de entrada son los que da .NET de verdad, copiados de una corrida.
/// </summary>
public class ExplicadorXsdTests
{
    private const string Inv = "urn:oasis:names:specification:ubl:schema:xsd:Invoice-2";
    private const string Cbc = "urn:oasis:names:specification:ubl:schema:xsd:CommonBasicComponents-2";

    [Fact]
    public void Elemento_fuera_de_orden()
    {
        var m = $"The element 'Invoice' in namespace '{Inv}' has invalid child element 'IssueDate' in namespace '{Cbc}'. " +
                $"List of possible elements expected: 'ID' in namespace '{Cbc}'.";

        Assert.Equal("Dentro de «Invoice», «cbc:IssueDate» sobra o está fuera de orden. " +
                     "En ese lugar el molde espera: cbc:ID.", ExplicadorXsd.Explicar(m));
    }

    [Fact]
    public void Varios_esperados_de_dos_espacios()
    {
        var m = $"The element 'Invoice' in namespace '{Inv}' has invalid child element 'Raro' in namespace '{Cbc}'. " +
                $"List of possible elements expected: 'Note, DueDate' in namespace '{Cbc}' as well as " +
                "'TaxTotal' in namespace 'urn:oasis:names:specification:ubl:schema:xsd:CommonAggregateComponents-2'.";

        Assert.Equal("Dentro de «Invoice», «cbc:Raro» sobra o está fuera de orden. " +
                     "En ese lugar el molde espera: cbc:Note, cbc:DueDate, cac:TaxTotal.", ExplicadorXsd.Explicar(m));
    }

    [Fact]
    public void Falta_un_elemento()
    {
        var m = $"The element 'Invoice' in namespace '{Inv}' has incomplete content. " +
                $"List of possible elements expected: 'IssueDate' in namespace '{Cbc}'.";

        Assert.Equal("A «Invoice» le falta un elemento obligatorio. Se esperaba: cbc:IssueDate.",
                     ExplicadorXsd.Explicar(m));
    }

    [Fact]
    public void Valor_que_no_es_del_tipo()
    {
        var m = $"The '{Cbc}:IssueDate' element is invalid - The value '14/10/2026' is invalid according to its " +
                "datatype 'http://www.w3.org/2001/XMLSchema:date' - The string '14/10/2026' is not a valid Date value.";

        Assert.Equal("El valor «14/10/2026» de «cbc:IssueDate» no es válido para el tipo xs:date.",
                     ExplicadorXsd.Explicar(m));
    }

    [Theory]
    [InlineData("The 'otro' attribute is not declared.", "El atributo «otro» no existe en el molde.")]
    [InlineData("The required attribute 'ver' is missing.", "Falta el atributo obligatorio «ver».")]
    public void Atributos(string original, string esperado)
    {
        Assert.Equal(esperado, ExplicadorXsd.Explicar(original));
    }

    [Fact]
    public void Lo_que_no_reconoce_queda_como_venia_pero_abreviado()
    {
        var m = $"Algo raro con 'Note' in namespace '{Cbc}'.";
        Assert.Equal("Algo raro con 'cbc:Note'.", ExplicadorXsd.Explicar(m));
    }
}