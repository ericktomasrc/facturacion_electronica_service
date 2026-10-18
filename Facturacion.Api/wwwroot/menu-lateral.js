// =============================================================================
// EL MENÚ DE LA IZQUIERDA del panel del servicio (14 de octubre de 2026).
//
// Cada página sigue armando su menú de arriba como siempre; este archivo lo
// esconde y pone en su lugar un menú lateral. Así basta una línea por página
// (<script src="/menu-lateral.js"></script>) y el menú vive en UN solo sitio:
// para agregar una pantalla, se agrega aquí.
//
// Pide /admin/yo por su cuenta para saber qué puede ver cada quien.
// OCULTAR NO ES PROTEGER: el servidor comprueba el permiso en cada petición.
//
// En pantallas angostas (celular) se vuelve una barra arriba con un botón
// «Menú».
// =============================================================================
(() => {
  const ANCHO = 236;

  // Por grupos, en el orden en que se usan. permiso:null = todos lo ven.
  const GRUPOS = [
    { titulo: "Operación", pantallas: [
      { url: "/diagnostico.html",  texto: "Estado del servicio", permiso: "diagnostico.ver",   icono: "pulso" },
      { url: "/vigilancia.html",   texto: "Vigilancia SUNAT",    permiso: "diagnostico.ver",   icono: "escudo" },
      { url: "/comprobantes.html", texto: "Comprobantes",        permiso: "comprobantes.ver",  icono: "hoja" }
    ]},
    { titulo: "Administración", pantallas: [
      { url: "/admin.html",        texto: "Empresas",            permiso: "empresas.ver",      icono: "edificio" },
      { url: "/usuarios.html",     texto: "Usuarios",            permiso: "usuarios.gestionar", icono: "personas" }
    ]},
    { titulo: "", pantallas: [
      { url: "/cuenta.html",       texto: "Mi cuenta",           permiso: null,                icono: "persona" }
    ]}
  ];

  // Iconos de trazo, 18 px, del color del texto.
  const ICONOS = {
    pulso:    '<path d="M3 12h4l2-6 4 12 2-6h6"/>',
    escudo:   '<path d="M12 3l7 3v5c0 4.5-3 8-7 10-4-2-7-5.5-7-10V6z"/><path d="M9 12l2 2 4-4"/>',
    hoja:     '<path d="M7 3h7l5 5v13H7z"/><path d="M14 3v5h5M10 13h6M10 17h6"/>',
    edificio: '<path d="M4 21V5l8-2v18M12 8l8 3v10M8 8v.01M8 12v.01M8 16v.01M16 14v.01M16 18v.01M2 21h20"/>',
    personas: '<circle cx="9" cy="8" r="3.5"/><path d="M2.5 20c.8-3.6 3.4-5.5 6.5-5.5s5.7 1.9 6.5 5.5"/><path d="M16 4.6a3.5 3.5 0 010 6.8M18 14.8c1.8.8 3 2.6 3.5 5.2"/>',
    persona:  '<circle cx="12" cy="8" r="4"/><path d="M4 21c1-4.2 4.1-6.5 8-6.5s7 2.3 8 6.5"/>'
  };

  const icono = n =>
    `<svg viewBox="0 0 24 24" width="18" height="18" fill="none" stroke="currentColor" ` +
    `stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${ICONOS[n] || ""}</svg>`;

  const esc = t => String(t ?? "").replace(/[&<>"']/g,
    c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));

  // --- Estilos. Usan los mismos colores de cada página (--panel, --borde…). --
  const estilo = document.createElement("style");
  estilo.textContent = `
    html.con-menu-lateral nav:not(.menu-lateral-nav),
    html.con-menu-lateral header h1 { display:none !important; }
    html.con-menu-lateral header { justify-content:flex-end; min-height:0; }
    html.con-menu-lateral header:not(:has(> :not(h1))) { display:none; }

    .menu-lateral { position:fixed; top:0; bottom:0; left:0; width:${ANCHO}px; z-index:60;
      display:flex; flex-direction:column; background:var(--panel, #fff);
      border-right:1px solid var(--borde, #e3e6ea);
      padding:20px 14px calc(16px + env(safe-area-inset-bottom, 0px)); overflow-y:auto;
      font:14.5px/1.4 ui-sans-serif, system-ui, "Segoe UI", sans-serif; }
    .menu-lateral .marca { display:flex; align-items:center; gap:10px; padding:2px 8px 18px;
      color:var(--texto, #1b1f24); text-decoration:none; }
    .menu-lateral .marca .logo { width:30px; height:30px; border-radius:8px; flex:none;
      display:grid; place-items:center; background:var(--acento, #2563eb); color:#fff;
      font-weight:600; font-size:13px; letter-spacing:.02em; }
    .menu-lateral .marca b { font-weight:600; font-size:14.5px; display:block; }
    .menu-lateral .marca span { color:var(--tenue, #5c6570); font-size:12px; }
    /* Cada página trae su propio estilo para «nav» (borde abajo, margen):
       aquí se anula, para que no se cuele en el menú lateral. */
    nav.menu-lateral-nav { display:flex; flex-direction:column; gap:2px; border:0 !important;
      margin:0 !important; padding:0; overflow:visible; }
    h2.titulo-pagina { font-size:20px !important; font-weight:500; margin:0 0 16px !important;
      color:var(--texto, #1b1f24) !important; text-transform:none !important; letter-spacing:0 !important; }
    .menu-lateral .grupo { color:var(--tenue, #5c6570); font-size:11.5px; text-transform:uppercase;
      letter-spacing:.07em; padding:14px 10px 6px; }
    .menu-lateral .separa { height:1px; background:var(--borde, #e3e6ea); margin:12px 6px 8px; }
    nav.menu-lateral-nav a { display:flex; align-items:center; gap:10px; padding:8px 10px;
      border-radius:8px; color:var(--tenue, #5c6570); text-decoration:none; border:0 !important;
      margin:0 !important; font-size:14.5px; }
    nav.menu-lateral-nav a:hover { background:var(--sutil, #f1f3f5); color:var(--texto, #1b1f24); }
    nav.menu-lateral-nav a.activo { background:var(--acento-fondo, rgba(37,99,235,.1));
      color:var(--acento, #2563eb); font-weight:500; }
    nav.menu-lateral-nav a:focus-visible { outline:2px solid var(--acento, #2563eb); outline-offset:1px; }
    .menu-lateral .pie { margin-top:auto; padding-top:14px; }
    .menu-lateral .pie #usuario-actual { display:flex; flex-wrap:wrap; gap:6px 10px; align-items:center;
      padding:10px; border-radius:10px; background:var(--sutil, #f1f3f5); font-size:13px; }
    .menu-lateral .pie #usuario-actual > span:first-child { flex-basis:100%; color:var(--texto, #1b1f24);
      overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
    .menu-lateral .boton-menu { display:none; }

    @media (min-width: 861px) {
      html.con-menu-lateral body { padding-left:${ANCHO + 28}px !important; }
    }

    /* Celular y tablet: barra arriba, el menú se despliega con el botón. */
    @media (max-width: 860px) {
      .menu-lateral { position:sticky; top:0; bottom:auto; width:auto; flex-direction:row;
        flex-wrap:wrap; align-items:center; padding:10px 0 10px; margin:-8px 0 14px;
        border-right:0; border-bottom:1px solid var(--borde, #e3e6ea); overflow:visible; }
      .menu-lateral .marca { padding:0; flex:1; }
      .menu-lateral .boton-menu { display:inline-flex; align-items:center; gap:6px;
        background:var(--panel, #fff); color:var(--texto, #1b1f24); border:1px solid var(--borde, #e3e6ea);
        border-radius:7px; padding:6px 11px; font:inherit; font-size:14px; cursor:pointer; }
      .menu-lateral .desplegable { display:none; flex-basis:100%; padding-top:8px; }
      .menu-lateral.abierto .desplegable { display:block; }
      .menu-lateral .pie { margin-top:8px; }
    }
  `;
  document.head.appendChild(estilo);
  document.documentElement.classList.add("con-menu-lateral");

  // --- El menú ----------------------------------------------------------------
  const aside = document.createElement("aside");
  aside.className = "menu-lateral";
  aside.setAttribute("aria-label", "Menú del panel");
  aside.innerHTML = `
    <a class="marca" href="/diagnostico.html">
      <span class="logo">FE</span>
      <span><b>Facturación electrónica</b><span>Panel del servicio</span></span>
    </a>
    <button class="boton-menu" type="button" aria-expanded="false" aria-controls="menu-lateral-desplegable">Menú</button>
    <div class="desplegable" id="menu-lateral-desplegable">
      <nav class="menu-lateral-nav"></nav>
      <div class="pie"></div>
    </div>`;
  document.body.prepend(aside);

  const boton = aside.querySelector(".boton-menu");
  boton.onclick = () => {
    const abierto = aside.classList.toggle("abierto");
    boton.setAttribute("aria-expanded", String(abierto));
  };

  // La caja del usuario (nombre, rol y «Salir») la llena cada página; aquí
  // solo se muda al pie del menú. Sus botones siguen funcionando igual.
  const usuario = document.getElementById("usuario-actual");
  if (usuario) aside.querySelector(".pie").appendChild(usuario);

  // El nombre de la pantalla, arriba del contenido: el título de la marca ya
  // está en el menú, y sin esto la página empieza directo en los botones.
  const actualUrl = location.pathname === "/" ? "/diagnostico.html" : location.pathname;
  const estaPantalla = GRUPOS.flatMap(g => g.pantallas).find(p => p.url === actualUrl);
  const cabecera = document.querySelector("header");
  if (estaPantalla && cabecera) {
    const h = document.createElement("h2");
    h.className = "titulo-pagina";
    h.textContent = estaPantalla.texto;
    cabecera.after(h);
  }

  function pintar(permisos) {
    const puede = p => p === null || permisos === null || permisos.includes(p);
    const actual = location.pathname === "/" ? "/diagnostico.html" : location.pathname;

    aside.querySelector(".menu-lateral-nav").innerHTML = GRUPOS.map(g => {
      const visibles = g.pantallas.filter(p => puede(p.permiso));
      if (!visibles.length) return "";
      const cabeza = g.titulo ? `<div class="grupo">${esc(g.titulo)}</div>` : `<div class="separa"></div>`;
      return cabeza + visibles.map(p =>
        `<a href="${p.url}" class="${actual === p.url ? "activo" : ""}"` +
        `${actual === p.url ? ' aria-current="page"' : ""}>${icono(p.icono)}<span>${esc(p.texto)}</span></a>`
      ).join("");
    }).join("");
  }

  // Mientras llega /admin/yo, el menú sale completo; si la sesión venció, la
  // propia página ya manda al ingreso.
  pintar(null);

  fetch("/admin/yo")
    .then(r => r.ok ? r.json() : null)
    .then(yo => { if (yo && Array.isArray(yo.permisos)) pintar(yo.permisos); })
    .catch(() => { /* el menú completo ya está pintado */ });
})();