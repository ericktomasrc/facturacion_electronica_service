// Fechas del panel, en hora de Lima.
//
// EL PROBLEMA QUE RESUELVE: el servidor guarda los instantes en UTC, que es
// lo correcto, pero nadie los convertía al mostrarlos. Un comprobante emitido
// a las 00:22 del sábado aparecía como 05:22, y a veces como del domingo.
//
// POR QUÉ NO BASTA toLocaleString("es-PE"): ese argumento es el IDIOMA, no la
// zona horaria. Le dice al navegador cómo escribir el mes y en qué orden poner
// los números, y nada más. La hora la sigue sacando del reloj de quien mira.
// En tu laptop en Lima sale bien por casualidad; desde el celular de un
// cliente en Miami, cinco horas corridas.
//
// ---------------------------------------------------------------------------
//
// HAY DOS CLASES DE FECHA Y SE TRATAN AL REVÉS. Confundirlas es el error que
// de verdad duele, porque mueve el día:
//
//   INSTANTES: cuándo pasó algo. creadoEn, ultimoIngreso, la hora de un
//   intento. Vienen en UTC, terminan en "Z", y HAY que convertirlos.
//   → fechaHora() y diaDe()
//
//   FECHAS DE NEGOCIO: qué día es el comprobante. fechaEmision,
//   fechaTraslado, validoHasta. NO son un instante: son un día, ya decidido
//   en hora de Perú por el servidor. Convertirlas las estropea — restarles
//   cinco horas a una factura del día 20 a las 00:00 la pasa al 19.
//   → dia()

const ZONA_PERU = "America/Lima";

/// Un instante UTC, en hora de Lima. Día y hora.
/// Ejemplo: "2026-09-20T07:23:12Z" → "20/09/2026, 02:23"
function fechaHora(valor) {
    if (!valor) return "—";

    return new Date(valor).toLocaleString("es-PE", {
        timeZone: ZONA_PERU,
        day: "2-digit", month: "2-digit", year: "numeric",
        hour: "2-digit", minute: "2-digit", hour12: false
    });
}

/// Un instante UTC, en hora de Lima, pero solo el día.
///
/// SE USA PARA COLUMNAS ESTRECHAS donde la hora no cabe, como "último
/// ingreso". Sigue convirtiendo: un ingreso a las 21:00 de Lima es el día
/// siguiente en UTC, y sin convertir se mostraría el día equivocado.
function diaDe(valor) {
    if (!valor) return "—";

    return new Date(valor).toLocaleDateString("es-PE", {
        timeZone: ZONA_PERU,
        day: "2-digit", month: "2-digit", year: "numeric"
    });
}

/// Una fecha de negocio, tal cual, en formato peruano.
///
/// NO CONVIERTE NADA, Y ES A PROPÓSITO. El valor llega como "2026-09-20" o
/// "2026-09-20T00:00:00" y ya es el día correcto: lo decidió el servidor en
/// hora de Perú cuando se emitió el comprobante.
///
/// Pasarlo por new Date() sería un error silencioso: sin la "Z" final,
/// JavaScript lo lee como medianoche del reloj de quien mira, y al
/// convertirlo a Lima desde cualquier zona al este de Perú retrocede un día.
/// La factura del 20 aparecería como del 19.
///
/// Por eso aquí solo se reordenan tres números.
function dia(valor) {
    if (!valor) return "—";

    const [a, m, d] = String(valor).slice(0, 10).split("-");

    return d && m && a ? `${d}/${m}/${a}` : String(valor);
}