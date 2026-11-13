(() => {
  "use strict";

  const $ = (sel, root = document) => root.querySelector(sel);
  const $$ = (sel, root = document) => Array.from(root.querySelectorAll(sel));

  const state = {
    catalogo: null,
    edificio: "E3",
    tipo: "alumno",
    placa: "ABC-123-A",
    mapa: null,
    zonaActiva: null,
    reco: null,
    opciones: [],
    estancia: null,
    busy: false,
    ws: null,
    tab: "alumnos",
    adminToken: sessionStorage.getItem("p49_admin_token") || null,
    admin: null,
    adminZona: "Z1",
    adminMap: null,
    activity: "movimientos",
    adminBusy: false
  };

  const TIPO_LABEL = {
    alumno: "Alumno",
    docente: "Docente",
    discapacidad: "Movilidad reducida",
    moto: "Motocicleta",
    visitante: "Visitante"
  };
  const TIPO_ABREV = {
    alumno: "A", docente: "D", discapacidad: "♿", moto: "M", visitante: "V"
  };
  const ESTADO_LABEL = {
    libre: "Libre", reservado: "Reservado", ocupado: "Ocupado",
    fuera_servicio: "Fuera de servicio"
  };
  const MOV_LABEL = {
    reserva_creada: "Reserva creada",
    reserva_confirmada: "Reserva confirmada",
    reserva_cancelada: "Reserva cancelada",
    reserva_expirada: "Reserva expirada",
    entrada_registrada: "Entrada registrada",
    salida_registrada: "Salida registrada",
    cajon_fuera_servicio: "Cajón fuera de servicio",
    cajon_habilitado: "Cajón habilitado",
    cajon_liberado: "Cajón liberado",
    zona_cerrada: "Estacionamiento cerrado",
    zona_abierta: "Estacionamiento reabierto",
    zona_iniciada: "Estacionamiento iniciado",
    escenario_iniciado: "Escenario iniciado"
  };
  const INC_LABEL = {
    cajon_reiniciado: "Cajón reiniciado",
    vehiculo_sin_permiso: "Vehículo sin permiso",
    sensor_inconsistente: "Sensor inconsistente",
    simulacion_con_duplicados: "Simulación con duplicados"
  };

  document.addEventListener("DOMContentLoaded", init);

  async function init() {
    bindTabs();
    bindStudent();
    bindModal();
    bindAdmin();

    try {
      await cargarCatalogo();
    } catch (error) {
      mostrarToast("No se pudo cargar el catálogo del campus.", "error");
    }

    await cargarMapa(state.edificio);
    conectarWS();
    await solicitarRecomendacion(false);
    await cargarEstancia(placaActual());

    setInterval(() => {
      if (state.tab === "admin" && state.adminToken && !state.adminBusy &&
          !document.hidden) {
        cargarAdmin(true);
      }
    }, 15000);

    setInterval(() => {
      if (state.reco && !state.reco.confirmada && state.reco.expira_en &&
          Math.floor(Date.now() / 1000) > state.reco.expira_en) {
        state.reco = null;
        renderReco();
        mostrarMensaje("La reserva temporal expiró. Solicita una nueva recomendación.", "error");
      }
    }, 10000);

    window.addEventListener("resize", debounce(() => {
      if (state.mapa) renderMapaEstudiante();
      if (state.adminMap) renderAdminMapa();
    }, 250));
  }

  /* ------------------------------- API ------------------------------- */

  async function fetchJSON(url, options = {}) {
    const headers = Object.assign({ "Accept": "application/json" }, options.headers || {});
    if (options.body !== undefined) headers["Content-Type"] = "application/json";
    if (options.admin && state.adminToken) {
      headers["x-admin-token"] = state.adminToken;
    }
    const response = await fetch(url, Object.assign({}, options, { headers }));
    const texto = await response.text();
    let datos = {};
    if (texto) {
      try { datos = JSON.parse(texto); }
      catch (_) { datos = { error: texto }; }
    }
    if (!response.ok) {
      const error = new Error(datos.mensaje || datos.error || `Error ${response.status}`);
      error.status = response.status;
      error.datos = datos;
      throw error;
    }
    return datos;
  }

  const getJSON = (url, admin = false) =>
    fetchJSON(url, { admin });
  const postJSON = (url, body, admin = false) =>
    fetchJSON(url, { method: "POST", body: JSON.stringify(body || {}), admin });

  /* ------------------------------- catálogo ------------------------------- */

  async function cargarCatalogo() {
    const datos = await getJSON("/api/catalogo");
    state.catalogo = datos;

    const edificios = datos.edificios || [];
    const tipos = datos.tipos_usuario || [];
    const zonas = datos.zonas || [];

    const opcionesEdificios = edificios
      .map(e => `<option value="${esc(e.id)}">${esc(e.nombre)}</option>`)
      .join("");
    ["select-edificio", "sim-edificio"].forEach(id => {
      const select = document.getElementById(id);
      if (select) select.innerHTML = opcionesEdificios;
    });

    const opcionesTipos = tipos
      .map(t => `<option value="${esc(t.id)}">${esc(t.nombre)}</option>`)
      .join("");
    ["select-tipo", "sim-tipo"].forEach(id => {
      const select = document.getElementById(id);
      if (select) select.innerHTML = opcionesTipos;
    });

    const opcionesZonas = zonas
      .map(z => `<option value="${esc(z.zona)}">${esc(z.nombre)}</option>`)
      .join("");
    const adminZona = document.getElementById("admin-zona-select");
    if (adminZona) adminZona.innerHTML = opcionesZonas;

    const existeE3 = edificios.some(e => e.id === "E3");
    state.edificio = existeE3 ? "E3" : (edificios[0] ? edificios[0].id : "E1");
    state.tipo = "alumno";
    state.adminZona = zonas[0] ? zonas[0].zona : "Z1";

    const selectEdificio = document.getElementById("select-edificio");
    const selectTipo = document.getElementById("select-tipo");
    if (selectEdificio) selectEdificio.value = state.edificio;
    if (selectTipo) selectTipo.value = state.tipo;
    if (adminZona) adminZona.value = state.adminZona;

    const simEdificio = document.getElementById("sim-edificio");
    const simTipo = document.getElementById("sim-tipo");
    if (simEdificio) simEdificio.value = state.edificio;
    if (simTipo) simTipo.value = state.tipo;

    renderDestinoZonas();
  }

  function datosEdificio(id) {
    return ((state.catalogo && state.catalogo.edificios) || [])
      .find(e => e.id === id) || null;
  }

  function nombreZona(id) {
    const enCatalogo = ((state.catalogo && state.catalogo.zonas) || [])
      .find(z => (z.zona || z.id) === id);
    if (enCatalogo) return enCatalogo.nombre;
    const enMapa = ((state.mapa && state.mapa.zonas) || [])
      .find(z => z.id === id);
    if (enMapa) return enMapa.nombre;
    return `Estacionamiento ${String(id || "").replace(/^Z/, "")}`;
  }

  function edificiosDeZona(id) {
    return ((state.catalogo && state.catalogo.edificios) || [])
      .filter(e => (e.zonas || []).includes(id))
      .map(e => e.id);
  }

  function etiquetaCajon(cajon) {
    const zonaId = String(cajon.id || "").split("-")[0];
    return `Cajón ${pad(cajon.numero)} · ${nombreZona(zonaId)}`;
  }

  function renderDestinoZonas() {
    const cont = document.getElementById("destino-zonas");
    if (!cont) return;
    const edificio = datosEdificio(state.edificio);
    if (!edificio) {
      cont.innerHTML = "";
      return;
    }
    const distancias = edificio.distancias || {};
    const zonas = (edificio.zonas || []).map(id =>
      `<span class="destino-pill">
        <strong>${esc(nombreZona(id))}</strong>
        <small>${esc(String(distancias[id] ?? ""))} min</small>
      </span>`).join("");
    cont.innerHTML =
      `<span class="destino-label">Estacionamientos recomendados</span>` +
      `<div class="destino-pills">${zonas}</div>`;
  }

  /* ------------------------------- alumno ------------------------------- */

  async function cargarMapa(edificio) {
    try {
      const datos = await getJSON(`/api/mapa?edificio=${encodeURIComponent(edificio)}`);
      state.mapa = datos;
      const zonas = datos.zonas || [];
      if (!zonas.some(z => z.id === state.zonaActiva)) {
        state.zonaActiva = zonas[0] ? zonas[0].id : null;
      }
      renderMapaEstudiante();
      enviarSuscripcion();
    } catch (error) {
      mostrarToast(error.message || "No se pudo cargar el mapa.", "error");
    }
  }

  function bindStudent() {
    const selectEdificio = document.getElementById("select-edificio");
    const selectTipo = document.getElementById("select-tipo");
    const inputPlaca = document.getElementById("input-placa");

    if (selectEdificio) {
      selectEdificio.addEventListener("change", async event => {
        state.edificio = event.target.value;
        await cambiarSolicitud();
      });
    }
    if (selectTipo) {
      selectTipo.addEventListener("change", async event => {
        state.tipo = event.target.value;
        await cambiarSolicitud();
      });
    }
    if (inputPlaca) {
      inputPlaca.addEventListener("input", event => {
        event.target.value = event.target.value.toUpperCase();
      });
      inputPlaca.addEventListener("change", async event => {
        state.placa = event.target.value.trim();
        await cargarEstancia(state.placa);
        if (state.reco) await cambiarSolicitud();
      });
    }

    const confirmar = document.getElementById("btn-confirmar");
    const ampliar = document.getElementById("btn-ampliar");
    const entrada = document.getElementById("btn-entrada");
    const salida = document.getElementById("btn-salida");
    const recoCard = document.getElementById("reco-card");
    const recoAltCard = document.getElementById("reco-alt-card");
    if (confirmar) confirmar.addEventListener("click", confirmarReserva);
    if (recoCard) recoCard.addEventListener("click", () => elegirOpcionDeCard(0));
    if (recoAltCard) recoAltCard.addEventListener("click", () => elegirOpcionDeCard(1));
    if (ampliar) ampliar.addEventListener("click", abrirModal);
    if (entrada) entrada.addEventListener("click", registrarEntrada);
    if (salida) salida.addEventListener("click", registrarSalida);

    bindChips(document.getElementById("chips-zonas"));
    bindChips(document.getElementById("modal-chips"));
    const campus = document.getElementById("campus-overview");
    if (campus) {
      campus.addEventListener("click", event => {
        const tile = event.target.closest("[data-campus-zona]");
        if (!tile) return;
        state.zonaActiva = tile.dataset.campusZona;
        renderMapaEstudiante();
      });
    }
    updateButtons();
  }

  async function cambiarSolicitud() {
    if (state.busy) return;
    renderDestinoZonas();
    await cancelarActual(true);
    state.reco = null;
    renderReco();
    await cargarMapa(state.edificio);
    await solicitarRecomendacion(false);
  }

  async function cancelarActual(silencioso = false) {
    if (!state.reco || state.reco.confirmada) return;
    const reco = state.reco;
    try {
      await postJSON(`/api/recomendaciones/${encodeURIComponent(reco.reserva_id)}/cancelar`,
                     { cajon_id: reco.cajon.id });
    } catch (_) {
      if (!silencioso) mostrarToast("La reserva anterior ya no estaba activa.", "error");
    }
  }

  function placaActual() {
    const input = document.getElementById("input-placa");
    return ((input && input.value) || state.placa || "").trim();
  }

  async function solicitarRecomendacion(esAlternativa, objetivoId) {
    if (state.busy) return;
    const placa = placaActual();
    if (!placa) {
      mostrarMensaje("Escribe una placa para solicitar tu cajón.", "error");
      return;
    }
    if (esAlternativa && !state.reco) return;

    state.busy = true;
    updateButtons();
    ocultarMensaje();

    try {
      let datos;
      if (esAlternativa) {
        datos = await postJSON(
          `/api/recomendaciones/${encodeURIComponent(state.reco.reserva_id)}/alternativa`,
          { cajon_id: state.reco.cajon.id, tipo_usuario: state.tipo,
            objetivo_id: objetivoId || "" }
        );
      } else {
        datos = await postJSON("/api/recomendaciones", {
          edificio: state.edificio,
          tipo_usuario: state.tipo,
          placa: placa.trim()
        });
      }
      state.reco = datos;
      state.reco.confirmada = false;
      if (datos.cajon && datos.cajon.zona) {
        state.zonaActiva = datos.cajon.zona;
      }
      renderReco();
      await cargarMapa(state.edificio);
      await cargarEstancia(placa);
      mostrarToast(esAlternativa
        ? "Opción actualizada. Confirma para conservarla."
        : "Cajón asignado automáticamente. Confirma para conservarlo.", "success");
    } catch (error) {
      if (esAlternativa) {
        mostrarMensaje(error.message || "No se pudo cambiar de opción. Intenta de nuevo.", "error");
      } else {
        state.reco = null;
        renderReco();
        await cargarEstancia(placa);
        mostrarMensaje(error.message || "No hay cajones disponibles para tu tipo de usuario.", "error");
      }
    } finally {
      state.busy = false;
      updateButtons();
    }
  }

  async function confirmarReserva() {
    if (!state.reco || state.reco.confirmada || state.busy) return;
    state.busy = true;
    updateButtons();
    try {
      await postJSON(
        `/api/recomendaciones/${encodeURIComponent(state.reco.reserva_id)}/confirmar`,
        { cajon_id: state.reco.cajon.id }
      );
      state.reco.confirmada = true;
      renderReco();
      await cargarEstancia(state.reco.placa);
      mostrarMensaje("Reserva confirmada. Registra tu entrada cuando llegues al estacionamiento.", "success");
      mostrarToast("Reserva confirmada.", "success");
      await cargarMapa(state.edificio);
    } catch (error) {
      mostrarMensaje(error.message || "No se pudo confirmar la reserva.", "error");
      await cargarMapa(state.edificio);
    } finally {
      state.busy = false;
      updateButtons();
    }
  }

  async function cargarEstancia(placa) {
    const limpia = String(placa || "").trim();
    if (!limpia) {
      state.estancia = null;
      renderEstancia();
      return;
    }
    try {
      const datos = await getJSON(
        `/api/estacionamientos/${encodeURIComponent(limpia)}`);
      state.estancia = datos && datos.activo ? datos : null;
    } catch (_) {
      state.estancia = null;
    }
    renderEstancia();
  }

  function renderEstancia() {
    const card = document.getElementById("estancia-card");
    const detalle = document.getElementById("estancia-detalle");
    const badge = document.getElementById("estancia-badge");
    if (!card || !detalle || !badge) return;

    const e = state.estancia;
    if (!e) {
      card.hidden = true;
      actualizarBotonesEstancia();
      return;
    }

    card.hidden = false;
    const zonaNombre = e.zona_nombre || nombreZona(e.zona);
    const lineas = [
      `Cajón <strong>${pad(e.numero)}</strong> · <strong>${esc(zonaNombre)}</strong>`,
      `Placa <strong>${esc(e.placa || placaActual())}</strong>`
    ];

    if (e.estado === "ocupado") {
      badge.className = "badge ocupada";
      badge.textContent = "Dentro";
      if (e.entrada_en) {
        lineas.push(`Entrada a las <strong>${hora(e.entrada_en)}</strong> · ${duracionTexto(e.entrada_en)}`);
      }
      lineas.push("Registra tu salida al retirarte para liberar el cajón.");
    } else if (e.confirmada) {
      badge.className = "badge confirmada";
      badge.textContent = "Confirmada";
      lineas.push("Reserva confirmada. Registra tu entrada al llegar.");
    } else {
      badge.className = "badge";
      badge.textContent = "Temporal";
      if (e.expira_en) {
        lineas.push(`Válida hasta las <strong>${hora(e.expira_en)}</strong>`);
      }
    }

    detalle.innerHTML = lineas.join("<br>");
    actualizarBotonesEstancia();
  }

  function actualizarBotonesEstancia() {
    const entrada = document.getElementById("btn-entrada");
    const salida = document.getElementById("btn-salida");
    if (!entrada || !salida) return;
    const e = state.estancia;
    entrada.disabled = !(e && e.puede_entrar) || state.busy;
    salida.disabled = !(e && e.puede_salir) || state.busy;
  }

  async function registrarEntrada() {
    if (state.busy) return;
    const placa = placaActual();
    const cajonId = (state.estancia && state.estancia.cajon_id) ||
      (state.reco && state.reco.cajon && state.reco.cajon.id) || "";
    state.busy = true;
    updateButtons();
    ocultarMensaje();
    try {
      const datos = await postJSON("/api/estacionamientos/entrada",
                                   { placa, cajon_id: cajonId });
      state.estancia = datos;
      if (state.reco) state.reco.confirmada = true;
      renderReco();
      renderEstancia();
      mostrarMensaje(`Entrada registrada en el cajón ${pad(datos.numero)}. ¡Bienvenido al campus!`, "success");
      await cargarMapa(state.edificio);
    } catch (error) {
      mostrarMensaje(error.message || "No se pudo registrar la entrada.", "error");
      await cargarEstancia(placa);
    } finally {
      state.busy = false;
      updateButtons();
    }
  }

  async function registrarSalida() {
    if (state.busy || !state.estancia) return;
    const placa = placaActual();
    const cajonId = state.estancia.cajon_id || "";
    state.busy = true;
    updateButtons();
    ocultarMensaje();
    try {
      const datos = await postJSON("/api/estacionamientos/salida",
                                   { placa, cajon_id: cajonId });
      state.estancia = null;
      state.reco = null;
      renderEstancia();
      renderReco();
      const tiempo = datos.duracion_seg
        ? ` después de ${duracionTexto(datos.entrada_en, datos.duracion_seg)}`
        : "";
      mostrarMensaje(`Salida registrada${tiempo}. El cajón ${pad(datos.numero)} quedó libre.`, "success");
      await cargarMapa(state.edificio);
    } catch (error) {
      mostrarMensaje(error.message || "No se pudo registrar la salida.", "error");
      await cargarEstancia(placa);
    } finally {
      state.busy = false;
      updateButtons();
    }
  }

  function renderReco() {
    const info = document.getElementById("reserva-info");
    const cards = [
      {
        el: document.getElementById("reco-card"),
        badge: document.getElementById("reco-badge"),
        cajon: document.getElementById("reco-cajon"),
        detalle: document.getElementById("reco-detalle")
      },
      {
        el: document.getElementById("reco-alt-card"),
        badge: document.getElementById("reco-alt-badge"),
        cajon: document.getElementById("reco-alt-cajon"),
        detalle: document.getElementById("reco-alt-detalle")
      }
    ];
    if (!info || cards.some(c => !c.el || !c.badge || !c.cajon || !c.detalle)) {
      return;
    }

    if (!state.reco) {
      state.opciones = [];
      cards.forEach((card, i) => {
        card.el.classList.remove("selected");
        card.el.setAttribute("aria-pressed", "false");
        card.el.disabled = true;
        if (i === 0) {
          card.el.hidden = false;
          card.el.classList.add("empty");
          card.badge.className = "badge";
          card.badge.textContent = "En espera";
          card.cajon.textContent = "—";
          card.detalle.textContent =
            "Selecciona un edificio para recibir una recomendación.";
        } else {
          card.el.hidden = true;
          card.el.classList.remove("empty");
        }
      });
      info.hidden = true;
      updateButtons();
      return;
    }

    const reco = state.reco;
    const zonas = zonasDeOpciones(reco);
    const opciones = zonas.map(zona => opcionDeZona(reco, zona));
    state.opciones = opciones;
    cards.forEach((card, i) => renderOpcion(card, opciones[i], reco));

    if (reco.confirmada) {
      const zonaNombre = reco.cajon.zona_nombre || nombreZona(reco.cajon.zona);
      info.hidden = false;
      info.innerHTML =
        `<strong>Reserva confirmada</strong><br>` +
        `Cajón <strong>${pad(reco.cajon.numero)}</strong> en ` +
        `<strong>${esc(zonaNombre)}</strong> · Placa <strong>${esc(reco.placa)}</strong><br>` +
        `Código: <strong>${esc(reco.reserva_id)}</strong>`;
    } else {
      info.hidden = true;
    }
    updateButtons();
  }

  // Devuelve las dos zonas que se muestran como tarjetas. Se respeta el orden
  // de los estacionamientos recomendados del edificio; si la recomendación
  // tuvo que salir de otras zonas, se usan las zonas que sí tienen opción.
  function zonasDeOpciones(reco) {
    const recomendadas = (state.mapa && Array.isArray(state.mapa.recomendadas))
      ? state.mapa.recomendadas : [];
    const zonas = [];
    recomendadas.forEach(z => {
      if (!zonas.includes(z)) zonas.push(z);
    });
    if (zonas.includes(reco.cajon.zona) && zonas.length >= 2) {
      return zonas.slice(0, 2);
    }
    const usadas = [reco.cajon.zona];
    (reco.alternativas || []).forEach(a => {
      if (!usadas.includes(a.zona)) usadas.push(a.zona);
    });
    return usadas.slice(0, 2);
  }

  function opcionDeZona(reco, zona) {
    if (reco.cajon.zona === zona) {
      return {
        id: reco.cajon.id,
        zona: reco.cajon.zona,
        zona_nombre: reco.cajon.zona_nombre,
        numero: reco.cajon.numero,
        tipo: reco.cajon.tipo,
        distancia: reco.cajon.distancia
      };
    }
    const alt = (reco.alternativas || []).find(a => a.zona === zona);
    if (!alt) return null;
    return {
      id: alt.cajon_id,
      zona: alt.zona,
      zona_nombre: alt.zona_nombre,
      numero: alt.numero,
      tipo: alt.tipo,
      distancia: alt.distancia
    };
  }

  function renderOpcion(card, opcion, reco) {
    const { el, badge, cajon, detalle } = card;
    if (!opcion || (reco.confirmada && opcion.id !== reco.cajon.id)) {
      el.hidden = true;
      el.classList.remove("selected");
      el.setAttribute("aria-pressed", "false");
      el.disabled = true;
      return;
    }

    const seleccionada = opcion.id === reco.cajon.id;
    el.hidden = false;
    el.classList.remove("empty");
    el.classList.toggle("selected", seleccionada);
    el.setAttribute("aria-pressed", seleccionada ? "true" : "false");
    el.disabled = reco.confirmada;

    const zonaNombre = opcion.zona_nombre || nombreZona(opcion.zona);
    const zonaId = String(opcion.id || "").split("-")[0];
    cajon.innerHTML =
      `<span class="reco-code-zona">${esc(zonaNombre)}</span>` +
      `<span class="reco-code-num">Cajón ${pad(opcion.numero)}` +
      (zonaId ? `<span class="reco-code-id">· ${esc(zonaId)}</span>` : "") +
      `</span>`;
    const tipo = TIPO_LABEL[opcion.tipo] || opcion.tipo;
    const distancia = opcion.distancia !== undefined
      ? ` · ${opcion.distancia} min caminando` : "";
    const expira = seleccionada && reco.expira_en && !reco.confirmada
      ? ` · válida hasta ${hora(reco.expira_en)}` : "";
    detalle.textContent = `${tipo}${distancia}${expira}` +
      (seleccionada ? "" : " · toca para elegir");

    badge.className = "badge";
    if (reco.confirmada && seleccionada) {
      badge.classList.add("confirmada");
      badge.textContent = "Confirmada";
    } else if (seleccionada) {
      badge.textContent = "Seleccionado";
    } else {
      badge.textContent = "Disponible";
    }
  }

  function elegirOpcionDeCard(index) {
    const opcion = (state.opciones || [])[index];
    if (!opcion || !state.reco || state.reco.confirmada || state.busy) return;
    if (opcion.id === state.reco.cajon.id) return;
    solicitarRecomendacion(true, opcion.id);
  }

  function updateButtons() {
    const confirmar = document.getElementById("btn-confirmar");
    const recoCard = document.getElementById("reco-card");
    const recoAltCard = document.getElementById("reco-alt-card");
    const activa = !!(state.reco && !state.reco.confirmada && !state.busy);
    if (confirmar) confirmar.disabled = !activa;
    if (recoCard) recoCard.disabled = !activa;
    if (recoAltCard) recoAltCard.disabled = !activa;
    actualizarBotonesEstancia();
  }

  function renderMapaEstudiante() {
    const zonas = (state.mapa && state.mapa.zonas) || [];
    const recomendadas = (state.mapa && state.mapa.recomendadas) || [];
    const zonasRecomendadas = zonas.filter(z => recomendadas.includes(z.id));
    renderCampusOverview();
    renderChips(document.getElementById("chips-zonas"), zonasRecomendadas);
    renderChips(document.getElementById("modal-chips"), zonasRecomendadas);

    const zona = zonas.find(z => z.id === state.zonaActiva) || zonas[0] || null;
    if (zona) state.zonaActiva = zona.id;

    const nombre = document.getElementById("mapa-zona-nombre");
    const meta = document.getElementById("mapa-zona-meta");
    const estado = document.getElementById("mapa-zona-estado");
    if (nombre) nombre.textContent = zona ? zona.nombre : "Sin estacionamientos disponibles";
    if (meta) {
      if (zona) {
        const r = zona.resumen || {};
        const aviso = recomendadas.includes(zona.id)
          ? ""
          : " · no es uno de los recomendados para tu edificio";
        meta.textContent = ` · ${r.libres || 0} libres de ${r.total || 0} · ${r.porcentaje_ocupacion || 0}% ocupado · vista compacta${aviso}`;
      } else {
        meta.textContent = "";
      }
    }
    if (estado) {
      estado.textContent = zona ? (zona.abierto ? "Abierto" : "Cerrado") : "—";
      estado.className = "mini-badge" + (zona && !zona.abierto ? " cerrada" : "");
    }

    const compacto = document.getElementById("mapa-compacto");
    if (compacto) {
      if (zona) renderMapa(compacto, zona, { compact: true, admin: false });
      else compacto.innerHTML = `<div class="activity-empty">No hay estacionamientos disponibles para este edificio.</div>`;
    }

    const modal = document.getElementById("modal-mapa");
    const amplio = document.getElementById("mapa-amplio");
    if (modal && !modal.hidden && amplio && zona) {
      renderMapa(amplio, zona, { compact: false, admin: false });
      const sub = document.getElementById("modal-sub");
      if (sub) sub.textContent = `${zona.nombre} · ${zona.cajones.length} cajones`;
    }
  }

  function renderCampusOverview() {
    const cont = document.getElementById("campus-overview");
    if (!cont || !state.mapa) return;
    const recomendadas = state.mapa.recomendadas || [];
    const zonas = state.mapa.zonas_campus || [];
    const edificio = datosEdificio(state.edificio);
    if (zonas.length === 0) {
      cont.innerHTML = "";
      return;
    }
    const nombreEdificio = edificio ? edificio.nombre : state.edificio;
    cont.innerHTML =
      `<div class="campus-overview-head">
        <strong>Cómo se distribuye el campus</strong>
        <span class="muted">Azul = recomendado para ${esc(nombreEdificio)}. Toca uno para ver su mapa.</span>
      </div>
      <div class="campus-overview-grid">
        ${zonas.map(zona => {
          const zonaId = zona.zona || zona.id;
          const esRecomendada = recomendadas.includes(zonaId);
          const abierta = zona.abierto !== false;
          const edificios = edificiosDeZona(zonaId);
          const activa = zonaId === state.zonaActiva ? " activa" : "";
          return `<button type="button" class="campus-zone${esRecomendada ? " recomendada" : ""}${abierta ? "" : " cerrada"}${activa}" data-campus-zona="${esc(zonaId)}">
            <span class="campus-zone-top">
              <span class="campus-zone-name">${esc(zona.nombre || nombreZona(zonaId))}</span>
              ${esRecomendada ? '<span class="campus-zone-tag">Recomendado</span>' : ""}
            </span>
            <span class="campus-zone-buildings">${edificios.map(esc).join(" · ")}</span>
            <span class="campus-zone-meta">
              <strong>${zona.libres || 0} libres</strong>
              <span>${abierta ? "Abierto" : "Cerrado"}</span>
            </span>
          </button>`;
        }).join("")}
      </div>`;
  }

  function renderChips(contenedor, zonas) {
    if (!contenedor) return;
    if (!zonas || zonas.length === 0) {
      contenedor.innerHTML = `<span class="muted" style="font-size:12px">Sin estacionamientos recomendados</span>`;
      return;
    }
    contenedor.innerHTML = zonas.map(zona => {
      const r = zona.resumen || {};
      const activa = zona.id === state.zonaActiva ? " active" : "";
      const cerrada = zona.abierto ? "" : " cerrada";
      const aviso = zona.abierto ? "" : `<span class="zone-closed">Cerrado</span>`;
      const edificios = edificiosDeZona(zona.id);
      return `<button type="button" class="zone-chip${activa}${cerrada}" data-zona="${esc(zona.id)}">
        <span class="zone-chip-info">
          <span class="zone-chip-main">${esc(zona.nombre || nombreZona(zona.id))}</span>
          <span class="zone-chip-sub">Cerca de ${edificios.map(esc).join(" · ")}</span>
        </span>
        <span class="zone-chip-side">
          <span class="zone-free">${r.libres || 0} libres</span>
          ${aviso}
        </span>
      </button>`;
    }).join("");
  }

  function bindChips(contenedor) {
    if (!contenedor) return;
    contenedor.addEventListener("click", event => {
      const chip = event.target.closest(".zone-chip");
      if (!chip) return;
      state.zonaActiva = chip.dataset.zona;
      renderMapaEstudiante();
    });
  }

  function renderMapa(contenedor, zona, opciones) {
    const todos = zona.cajones || [];
    const cajones = opciones.compact
      ? cajonesCompactos(todos, zona)
      : todos;
    const cols = opciones.admin
      ? (window.innerWidth < 600 ? 6 : window.innerWidth < 1120 ? 12 : 20)
      : opciones.compact
        ? (window.innerWidth < 600 ? 3 : 5)
        : (window.innerWidth < 600 ? 6 : 12);

    contenedor.innerHTML = "";
    if (cajones.length === 0) {
      contenedor.innerHTML = `<div class="activity-empty">Sin cajones disponibles.</div>`;
      return;
    }
    contenedor.style.setProperty("--cols", cols);

    const mitad = Math.ceil(cajones.length / 2);
    const bloques = [cajones.slice(0, mitad), cajones.slice(mitad)];
    const lote = document.createElement("div");
    lote.className = "lot";

    const etiquetaAcceso = document.createElement("div");
    etiquetaAcceso.className = "lot-label";
    etiquetaAcceso.textContent = "Acceso / entrada";
    lote.appendChild(etiquetaAcceso);

    bloques.forEach((bloque, indice) => {
      if (indice === 1) {
        const carril = document.createElement("div");
        carril.className = "lane";
        carril.innerHTML = "<span>Circulación</span>";
        lote.appendChild(carril);
      }
      const grid = document.createElement("div");
      grid.className = "spaces-grid";
      grid.style.setProperty("--cols", cols);
      bloque.forEach(cajon => grid.appendChild(crearCajon(cajon, opciones)));
      lote.appendChild(grid);
    });

    const etiquetaSalida = document.createElement("div");
    etiquetaSalida.className = "lot-label";
    etiquetaSalida.textContent = "Salida";
    lote.appendChild(etiquetaSalida);
    contenedor.appendChild(lote);
  }

  // En la vista compacta se muestran 30 cajones, pero se centra la ventana en
  // el cajón recomendado para que la estrella del mapa sea visible.
  function cajonesCompactos(todos, zona) {
    const limite = 30;
    if (!state.reco || !state.reco.cajon ||
        state.reco.cajon.zona !== zona.id) {
      return todos.slice(0, limite);
    }
    const indice = todos.findIndex(c => c.id === state.reco.cajon.id);
    if (indice < 0) return todos.slice(0, limite);
    const inicio = Math.max(0, Math.min(indice - 14, todos.length - limite));
    return todos.slice(inicio, inicio + limite);
  }

  function crearCajon(cajon, opciones) {
    const boton = document.createElement("button");
    boton.type = "button";
    const estado = cajon.estado || "fuera_servicio";
    const claseEstado = estado === "fuera_servicio" ? "fuera" : estado;
    boton.className = `space ${claseEstado}`;
    boton.dataset.id = cajon.id;
    boton.dataset.estado = estado;
    const recomendado = !opciones.admin && state.reco &&
      state.reco.cajon && state.reco.cajon.id === cajon.id;
    if (recomendado) boton.classList.add("recomendado");
    boton.title = `${etiquetaCajon(cajon)} · ${TIPO_LABEL[cajon.tipo] || cajon.tipo} · ${ESTADO_LABEL[estado] || estado}` +
      (opciones.admin && cajon.placa ? ` · Placa ${cajon.placa}` : "");
    if (opciones.admin && cajon.placa) boton.classList.add("con-placa");
    boton.innerHTML =
      `<span class="bay"></span>` +
      `<span class="space-num">${pad(cajon.numero)}</span>` +
      `<span class="space-tipo">${esc(TIPO_ABREV[cajon.tipo] || "")}</span>` +
      (opciones.admin && cajon.placa
        ? `<span class="space-placa">${esc(cajon.placa)}</span>`
        : "");
    boton.addEventListener("click", () => {
      if (opciones.admin) onAdminCajonClick(cajon);
      else onCajonEstudianteClick(cajon, recomendado);
    });
    return boton;
  }

  function onCajonEstudianteClick(cajon, recomendado) {
    if (recomendado) {
      mostrarToast(`Este es tu cajón recomendado: ${etiquetaCajon(cajon)}. Confirma la reserva para conservarlo.`, "success");
      return;
    }
    if (cajon.estado === "libre") {
      mostrarToast("La asignación es automática. Elige la otra tarjeta para cambiarte de estacionamiento.", "");
    } else {
      mostrarToast(`${etiquetaCajon(cajon)}: ${ESTADO_LABEL[cajon.estado] || cajon.estado}.`, "");
    }
  }

  /* ------------------------------- modal ------------------------------- */

  function bindModal() {
    const modal = document.getElementById("modal-mapa");
    const cerrar = document.getElementById("btn-cerrar-modal");
    if (cerrar) cerrar.addEventListener("click", cerrarModal);
    if (modal) {
      modal.addEventListener("click", event => {
        if (event.target.matches("[data-cerrar-modal]")) cerrarModal();
      });
    }
    document.addEventListener("keydown", event => {
      if (event.key === "Escape") cerrarModal();
    });
  }

  function abrirModal() {
    const modal = document.getElementById("modal-mapa");
    if (!modal) return;
    modal.hidden = false;
    document.body.style.overflow = "hidden";
    renderMapaEstudiante();
  }

  function cerrarModal() {
    const modal = document.getElementById("modal-mapa");
    if (!modal || modal.hidden) return;
    modal.hidden = true;
    document.body.style.overflow = "";
  }

  /* ------------------------------- admin ------------------------------- */

  function bindTabs() {
    $$(".tab").forEach(tab => {
      tab.addEventListener("click", async () => {
        state.tab = tab.dataset.tab;
        $$(".tab").forEach(t => {
          const activo = t === tab;
          t.classList.toggle("active", activo);
          t.setAttribute("aria-selected", activo ? "true" : "false");
        });
        const alumnos = document.getElementById("vista-alumnos");
        const admin = document.getElementById("vista-admin");
        if (alumnos) alumnos.hidden = state.tab !== "alumnos";
        if (admin) admin.hidden = state.tab !== "admin";
        if (state.tab === "admin") {
          await abrirAdmin();
        } else {
          enviarSuscripcion();
        }
      });
    });
  }

  async function abrirAdmin() {
    const pin = document.getElementById("admin-pin");
    const panel = document.getElementById("admin-panel");
    if (!state.adminToken) {
      if (pin) pin.hidden = false;
      if (panel) panel.hidden = true;
      return;
    }
    if (pin) pin.hidden = true;
    if (panel) panel.hidden = false;
    await cargarAdmin();
  }

  function bindAdmin() {
    const formPin = document.getElementById("form-pin");
    const inputPin = document.getElementById("input-pin");
    if (inputPin) {
      inputPin.addEventListener("input", event => {
        event.target.value = event.target.value.replace(/\D/g, "").slice(0, 6);
      });
    }
    if (formPin) formPin.addEventListener("submit", iniciarSesionAdmin);

    const refrescar = document.getElementById("btn-refrescar-admin");
    const salir = document.getElementById("btn-salir-admin");
    const escenario = document.getElementById("btn-escenario");
    if (refrescar) refrescar.addEventListener("click", () => cargarAdmin());
    if (salir) salir.addEventListener("click", cerrarSesionAdmin);
    if (escenario) escenario.addEventListener("click", ejecutarEscenario);

    const formSim = document.getElementById("form-simulacion");
    if (formSim) formSim.addEventListener("submit", ejecutarSimulacion);

    const selectZona = document.getElementById("admin-zona-select");
    if (selectZona) {
      selectZona.addEventListener("change", async event => {
        state.adminZona = event.target.value;
        await cargarAdminMapa();
      });
    }

    const zonas = document.getElementById("admin-zonas");
    if (zonas) {
      zonas.addEventListener("click", event => {
        const boton = event.target.closest("[data-zona]");
        if (!boton) return;
        cambiarEstadoZona(boton.dataset.zona, boton.dataset.estado);
      });
    }

    const actividad = document.querySelector(".activity-tabs");
    if (actividad) {
      actividad.addEventListener("click", event => {
        const chip = event.target.closest("[data-activity]");
        if (!chip) return;
        state.activity = chip.dataset.activity;
        $$(".activity-tabs .chip").forEach(c => c.classList.toggle("active", c === chip));
        renderActivity();
      });
    }

    const diagnostics = document.getElementById("diagnostics");
    if (diagnostics) {
      diagnostics.addEventListener("toggle", () => {
        if (diagnostics.open) cargarDiagnostico();
      });
    }
  }

  async function iniciarSesionAdmin(event) {
    event.preventDefault();
    const input = document.getElementById("input-pin");
    const error = document.getElementById("pin-error");
    const pin = input ? input.value.trim() : "";
    if (error) error.hidden = true;
    if (!/^\d{6}$/.test(pin)) {
      if (error) {
        error.textContent = "Escribe un PIN de 6 dígitos.";
        error.hidden = false;
      }
      return;
    }
    try {
      const datos = await postJSON("/api/admin/sesion", { pin });
      state.adminToken = datos.token;
      sessionStorage.setItem("p49_admin_token", datos.token);
      if (input) input.value = "";
      const gate = document.getElementById("admin-pin");
      const panel = document.getElementById("admin-panel");
      if (gate) gate.hidden = true;
      if (panel) panel.hidden = false;
      await cargarAdmin();
    } catch (err) {
      if (error) {
        error.textContent = err.status === 401 ? "PIN incorrecto." : "No se pudo iniciar sesión.";
        error.hidden = false;
      }
    }
  }

  function cerrarSesionAdmin() {
    state.adminToken = null;
    state.admin = null;
    state.adminMap = null;
    sessionStorage.removeItem("p49_admin_token");
    const gate = document.getElementById("admin-pin");
    const panel = document.getElementById("admin-panel");
    if (gate) gate.hidden = false;
    if (panel) panel.hidden = true;
    mostrarToast("Sesión administrativa cerrada.", "");
  }

  async function cargarAdmin(silencioso = false) {
    if (!state.adminToken) return;
    try {
      const datos = await getJSON("/api/admin/estado", true);
      state.admin = datos;
      renderAdminStats();
      renderAdminZonas();
      renderActivity();
      if (!silencioso || !state.adminMap) await cargarAdminMapa();
    } catch (error) {
      if (error.status === 401) {
        cerrarSesionAdmin();
        mostrarToast("La sesión expiró. Vuelve a ingresar el PIN.", "error");
      } else if (!silencioso) {
        mostrarToast(error.message || "No se pudo cargar el panel.", "error");
      }
    }
  }

  async function cargarAdminMapa() {
    if (!state.adminToken) return;
    try {
      const datos = await getJSON(
        `/api/admin/cajones?zona=${encodeURIComponent(state.adminZona)}`, true);
      state.adminMap = datos;
      const select = document.getElementById("admin-zona-select");
      if (select) select.value = state.adminZona;
      renderAdminMapa();
    } catch (error) {
      if (error.status === 401) cerrarSesionAdmin();
      else mostrarToast(error.message || "No se pudo cargar el mapa del estacionamiento.", "error");
    }
  }

  function renderAdminStats() {
    const contenedor = document.getElementById("admin-stats");
    if (!contenedor || !state.admin) return;
    const r = state.admin.resumen || {};
    const zonaAbiertas = r.zonas_abiertas || 0;
    const tarjetas = [
      ["Total de cajones", r.total || 0, `${zonaAbiertas} estacionamientos abiertos`, true],
      ["Disponibles", r.libres || 0, "listos para reservar", false],
      ["Reservados", r.reservados || 0, "apartados por usuarios", false],
      ["Ocupados", r.ocupados || 0, "autos dentro", false],
      ["Fuera de servicio", r.fuera_servicio || 0, "en mantenimiento", false],
      ["Ocupación", `${r.porcentaje_ocupacion || 0}%`, "del campus", false]
    ];
    contenedor.innerHTML = tarjetas.map(([etiqueta, valor, sub, acento]) =>
      `<div class="stat-card${acento ? " accent" : ""}">
        <div class="stat-label">${esc(etiqueta)}</div>
        <div class="stat-value">${esc(String(valor))}</div>
        <div class="stat-sub">${esc(sub)}</div>
      </div>`).join("");
  }

  function renderAdminZonas() {
    const contenedor = document.getElementById("admin-zonas");
    if (!contenedor || !state.admin) return;
    const zonas = state.admin.zonas || [];
    contenedor.innerHTML = zonas.map(zona => {
      const r = zona;
      const ocupacion = r.porcentaje_ocupacion || 0;
      const abierto = !!r.abierto;
      return `<div class="zone-row">
        <div class="zone-id">${esc(String(r.zona).replace(/^Z/, ""))}</div>
        <div>
          <div class="zone-name">${esc(r.nombre)}</div>
          <div class="zone-meta">${r.libres} libres · ${r.reservados} reservados · ${r.ocupados} ocupados · ${r.fuera_servicio} fuera</div>
          <div class="progress${ocupacion >= 95 ? " full" : ""}"><span style="width:${Math.min(100, ocupacion)}%"></span></div>
        </div>
        <div class="zone-actions">
          <span class="badge${abierto ? " confirmada" : " error"}">${abierto ? "Abierto" : "Cerrado"}</span>
          <button type="button" class="btn btn-ghost" data-zona="${esc(r.zona)}" data-estado="${abierto ? "cerrado" : "abierto"}">${abierto ? "Cerrar" : "Reabrir"}</button>
        </div>
      </div>`;
    }).join("");
  }

  async function cambiarEstadoZona(zona, estado) {
    if (state.adminBusy) return;
    const nombre = nombreZona(zona);
    if (estado === "cerrado" && !confirm(`¿Cerrar ${nombre}? Se liberarán las reservas pendientes.`)) return;
    state.adminBusy = true;
    try {
      await postJSON(`/api/admin/zonas/${encodeURIComponent(zona)}`, { estado }, true);
      mostrarToast(`${nombre}: ${estado === "cerrado" ? "cerrado" : "reabierto"}.`, "success");
      await cargarAdmin();
      await cargarMapa(state.edificio);
    } catch (error) {
      mostrarToast(error.message || "No se pudo cambiar el estacionamiento.", "error");
    } finally {
      state.adminBusy = false;
    }
  }

  function renderAdminMapa() {
    const contenedor = document.getElementById("admin-mapa");
    const pista = document.getElementById("admin-map-hint");
    if (!contenedor || !state.adminMap) return;
    const zona = state.adminMap;
    if (pista) {
      pista.textContent = `${zona.total || 0} cajones · ${zona.abierto ? "abierto" : "cerrado"} · libre → mantenimiento · gris → habilitar · ocupado/reservado → liberar (se muestra la placa)`;
    }
    renderMapa(contenedor,
               { id: zona.zona, nombre: zona.nombre, cajones: zona.cajones || [] },
               { compact: false, admin: true });
  }

  async function onAdminCajonClick(cajon) {
    if (state.adminBusy) return;
    if (cajon.estado === "libre") {
      if (!confirm(`¿Marcar ${cajon.id} fuera de servicio?`)) return;
      await actualizarCajonAdmin(cajon.id, "fuera_servicio",
                                 "Mantenimiento desde panel");
    } else if (cajon.estado === "fuera_servicio") {
      await actualizarCajonAdmin(cajon.id, "libre", "Reactivado desde panel");
    } else if (cajon.estado === "ocupado") {
      const quien = cajon.placa ? ` por la placa ${cajon.placa}` : "";
      if (!confirm(`¿Liberar ${cajon.id}? Está ocupado${quien}. La liberación quedará registrada como acción administrativa.`)) return;
      await liberarCajonAdmin(cajon.id, "Liberación administrativa");
    } else if (cajon.estado === "reservado") {
      const quien = cajon.placa ? ` de la placa ${cajon.placa}` : "";
      if (!confirm(`¿Liberar la reserva de ${cajon.id}?${quien}`)) return;
      await liberarCajonAdmin(cajon.id, "Reserva liberada desde panel");
    } else {
      mostrarToast("Este cajón no se puede modificar.", "");
    }
  }

  async function liberarCajonAdmin(cajonId, motivo) {
    state.adminBusy = true;
    try {
      await postJSON(`/api/admin/cajones/${encodeURIComponent(cajonId)}`,
                     { accion: "liberar", motivo }, true);
      mostrarToast(`${cajonId}: cajón liberado.`, "success");
      await cargarAdmin();
      await cargarMapa(state.edificio);
    } catch (error) {
      mostrarToast(error.message || "No se pudo liberar el cajón.", "error");
    } finally {
      state.adminBusy = false;
    }
  }

  async function actualizarCajonAdmin(cajonId, estado, motivo) {
    state.adminBusy = true;
    try {
      await postJSON(`/api/admin/cajones/${encodeURIComponent(cajonId)}`,
                     { estado, motivo }, true);
      mostrarToast(`${cajonId}: ${estado === "libre" ? "habilitado" : "fuera de servicio"}.`, "success");
      await cargarAdmin();
      await cargarMapa(state.edificio);
    } catch (error) {
      mostrarToast(error.message || "No se pudo actualizar el cajón.", "error");
    } finally {
      state.adminBusy = false;
    }
  }

  function renderActivity() {
    const contenedor = document.getElementById("activity-list");
    if (!contenedor || !state.admin) return;
    const esMovimiento = state.activity === "movimientos";
    const items = (esMovimiento ? state.admin.movimientos : state.admin.incidencias) || [];
    if (items.length === 0) {
      contenedor.innerHTML = `<div class="activity-empty">Sin ${esMovimiento ? "movimientos" : "incidencias"} registradas.</div>`;
      return;
    }
    contenedor.innerHTML = items.map(item => {
      const tipo = item.tipo || "";
      const titulo = (esMovimiento ? MOV_LABEL[tipo] : INC_LABEL[tipo]) || tipo;
      const detalle = detalleActividad(item.datos || {});
      return `<div class="activity-item">
        <div class="activity-top">
          <span class="activity-title">${esc(titulo)}</span>
          <span class="activity-time">${esc(fechaCorta(item.ts))}</span>
        </div>
        <div class="activity-detail">${esc(detalle)}</div>
      </div>`;
    }).join("");
  }

  function detalleActividad(datos) {
    const etiquetas = {
      zona: "Ubicación", cajon: "Cajón", placa: "Placa", reserva_id: "Reserva",
      motivo: "Motivo", edificio: "Edificio", detalle: "Detalle",
      total: "Total", libres: "Libres", autos: "Autos",
      zona_cerrada: "Estacionamiento cerrado", razon: "Razón", duplicados: "Duplicados"
    };
    return Object.entries(datos)
      .filter(([, valor]) => valor !== null && valor !== undefined && valor !== "")
      .map(([clave, valor]) => {
        const mostrado = (clave === "zona" || clave === "zona_cerrada")
          ? nombreZona(String(valor))
          : valor;
        return `${etiquetas[clave] || clave}: ${mostrado}`;
      })
      .join(" · ");
  }

  async function ejecutarSimulacion(event) {
    event.preventDefault();
    if (state.adminBusy || !state.adminToken) return;
    const cantidad = parseInt((document.getElementById("sim-cantidad") || {}).value || "120", 10);
    const edificio = (document.getElementById("sim-edificio") || {}).value || state.edificio;
    const tipo = (document.getElementById("sim-tipo") || {}).value || state.tipo;
    await correrSimulacion({ solicitudes: cantidad, edificio, tipo_usuario: tipo });
  }

  async function ejecutarEscenario() {
    if (state.adminBusy || !state.adminToken) return;
    if (!confirm("El escenario completo simula 1,200 autos, cierra temporalmente el Estacionamiento 4 y libera los cajones al terminar. ¿Continuar?")) return;
    await correrSimulacion(null, true);
  }

  async function correrSimulacion(cuerpo, escenario = false) {
    state.adminBusy = true;
    const resultado = document.getElementById("sim-resultado");
    if (resultado) {
      resultado.hidden = false;
      resultado.innerHTML = `<div class="activity-empty">${escenario ? "Ejecutando escenario de 1,200 autos…" : "Ejecutando solicitudes concurrentes…"}</div>`;
    }
    try {
      const datos = escenario
        ? await postJSON("/api/admin/escenario", {}, true)
        : await postJSON("/api/admin/simulacion", cuerpo, true);
      if (resultado) renderSimResultado(resultado, datos);
      mostrarToast(escenario ? "Escenario completado." : "Simulación completada.", "success");
      await cargarAdmin(true);
    } catch (error) {
      if (resultado) resultado.innerHTML = `<div class="activity-empty">${esc(error.message || "La simulación falló.")}</div>`;
      mostrarToast(error.message || "No se pudo ejecutar la simulación.", "error");
    } finally {
      state.adminBusy = false;
    }
  }

  function renderSimResultado(contenedor, datos) {
    const escenario = datos.escenario
      ? `<p class="hint">Escenario: ${datos.escenario.autos} autos · ${esc(nombreZona(datos.escenario.zona_cerrada))} cerrado por obra · ${datos.escenario.incidencias_inyectadas} incidencias inyectadas.</p>`
      : "";
    const metricas = [
      ["Solicitudes", datos.solicitudes, ""],
      ["Asignadas", datos.asignadas, "ok"],
      ["Rechazadas", datos.rechazadas, datos.rechazadas > 0 ? "bad" : ""],
      ["Duplicados", datos.duplicados, datos.duplicados > 0 ? "bad" : "ok"],
      ["Tiempo", `${datos.tiempo_ms} ms`, ""]
    ];
    const porZona = datos.por_zona || {};
    const maximo = Math.max(1, ...Object.values(porZona));
    const barras = Object.entries(porZona).map(([zona, total]) =>
      `<div class="zone-bar"><span>${esc(nombreZona(zona))}</span><div class="bar"><span style="width:${Math.round(total / maximo * 100)}%"></span></div><span>${total}</span></div>`
    ).join("");
    contenedor.innerHTML =
      `<h3>${datos.tipo === "escenario_completo" ? "Escenario completo" : "Simulación concurrente"}</h3>` +
      `<div class="sim-metrics">` +
      metricas.map(([etiqueta, valor, clase]) =>
        `<div class="sim-metric ${clase}"><span>${esc(etiqueta)}</span><strong>${esc(String(valor))}</strong></div>`
      ).join("") +
      `</div>` +
      (barras ? `<div class="zone-bars">${barras}</div>` : "") +
      escenario;
  }

  async function cargarDiagnostico() {
    const pre = document.getElementById("diagnostico");
    if (!pre || !state.adminToken) return;
    pre.textContent = "Consultando nodo…";
    try {
      const datos = await getJSON("/api/admin/diagnostico", true);
      pre.textContent = JSON.stringify(datos, null, 2);
    } catch (error) {
      pre.textContent = error.message || "No se pudo consultar el nodo.";
    }
  }

  /* ------------------------------- WebSocket ------------------------------- */

  function conectarWS() {
    const protocolo = location.protocol === "https:" ? "wss:" : "ws:";
    try {
      state.ws = new WebSocket(`${protocolo}//${location.host}/ws/mapa`);
    } catch (_) {
      estadoConexion(false);
      setTimeout(conectarWS, 5000);
      return;
    }
    state.ws.addEventListener("open", () => {
      estadoConexion(true);
      enviarSuscripcion();
    });
    state.ws.addEventListener("message", event => {
      try {
        const mensaje = JSON.parse(event.data);
        if (mensaje.tipo === "mapa" && mensaje.edificio === state.edificio &&
            mensaje.datos) {
          state.mapa = mensaje.datos;
          renderMapaEstudiante();
        }
      } catch (_) { /* mensaje no JSON */ }
    });
    state.ws.addEventListener("close", () => {
      estadoConexion(false);
      setTimeout(conectarWS, 5000);
    });
    state.ws.addEventListener("error", () => estadoConexion(false));
  }

  function enviarSuscripcion() {
    if (state.ws && state.ws.readyState === WebSocket.OPEN) {
      state.ws.send(JSON.stringify({ accion: "suscribir", edificio: state.edificio }));
    }
  }

  function estadoConexion(online) {
    const pill = document.getElementById("conexion");
    const texto = document.getElementById("conexion-texto");
    if (pill) pill.className = "status-pill " + (online ? "online" : "offline");
    if (texto) texto.textContent = online ? "En línea" : "Sin conexión";
  }

  /* ------------------------------- utilidades ------------------------------- */

  function mostrarMensaje(texto, tipo = "") {
    const caja = document.getElementById("mensaje-alumno");
    if (!caja) return;
    caja.hidden = false;
    caja.className = "message" + (tipo ? ` ${tipo}` : "");
    caja.textContent = texto;
  }

  function ocultarMensaje() {
    const caja = document.getElementById("mensaje-alumno");
    if (caja) {
      caja.hidden = true;
      caja.textContent = "";
    }
  }

  let toastTimer = null;
  function mostrarToast(texto, tipo = "") {
    const toast = document.getElementById("toast");
    if (!toast) return;
    toast.hidden = false;
    toast.className = "toast" + (tipo ? ` ${tipo}` : "");
    toast.textContent = texto;
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => { toast.hidden = true; }, 3400);
  }

  function esc(valor) {
    return String(valor === undefined || valor === null ? "" : valor)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;")
      .replace(/'/g, "&#39;");
  }

  function pad(numero) {
    return String(numero || 0).padStart(3, "0");
  }

  function hora(segundos) {
    try {
      return new Date(segundos * 1000).toLocaleTimeString("es-MX",
        { hour: "2-digit", minute: "2-digit" });
    } catch (_) { return ""; }
  }

  function duracionTexto(entradaEn, duracionSeg) {
    let segundos = duracionSeg;
    if (segundos === undefined || segundos === null) {
      if (!entradaEn) return "";
      segundos = Math.max(0, Math.floor(Date.now() / 1000) - entradaEn);
    }
    const minutos = Math.floor(segundos / 60);
    if (minutos < 1) return "menos de 1 min";
    if (minutos < 60) return `${minutos} min`;
    return `${Math.floor(minutos / 60)} h ${minutos % 60} min`;
  }

  function fechaCorta(segundos) {
    if (!segundos) return "";
    try {
      return new Date(segundos * 1000).toLocaleString("es-MX",
        { day: "2-digit", month: "short", hour: "2-digit", minute: "2-digit" });
    } catch (_) { return ""; }
  }

  function debounce(fn, espera) {
    let timer = null;
    return (...args) => {
      clearTimeout(timer);
      timer = setTimeout(() => fn(...args), espera);
    };
  }
})();
