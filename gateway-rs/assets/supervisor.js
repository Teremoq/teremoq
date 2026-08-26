const element = id => document.getElementById(id);

const formatBytes = value => {
  if (!value) return "0 B";
  const units = ["B", "KiB", "MiB", "GiB"];
  const index = Math.min(Math.floor(Math.log(value) / Math.log(1024)), 3);
  return `${(value / 1024 ** index).toFixed(index ? 1 : 0)} ${units[index]}`;
};

const formatAge = value => {
  if (value == null) return "—";
  return value < 1000 ? `${value} ms` : `${(value / 1000).toFixed(1)} s`;
};

const formatTime = value => {
  const seconds = Math.floor(value / 1000);
  const hours = Math.floor(seconds / 3600);
  const minutes = Math.floor((seconds % 3600) / 60);
  return `${String(hours).padStart(2, "0")}:${String(minutes).padStart(2, "0")}:${String(seconds % 60).padStart(2, "0")}`;
};

const escapeHtml = value => String(value ?? "—").replace(
  /[&<>"']/g,
  character => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[character],
);

const safeStatus = value => (
  ["active", "stale", "waiting", "pending", "unavailable"].includes(value)
    ? value
    : "unavailable"
);

function renderScheduler(snapshot) {
  const scheduler = snapshot.scheduler ?? {};
  element("scheduler-subscribers").textContent = (scheduler.subscribers ?? 0).toLocaleString();
  element("scheduler-queued").textContent = (scheduler.queued_objects ?? 0).toLocaleString();
  element("scheduler-bytes").textContent = formatBytes(scheduler.queued_bytes ?? 0);
  element("scheduler-accepted").textContent = (scheduler.accepted ?? 0).toLocaleString();
  element("scheduler-dropped").textContent = (scheduler.dropped ?? 0).toLocaleString();
  element("scheduler-evicted").textContent = (scheduler.evicted ?? 0).toLocaleString();
}

function renderMoq(snapshot) {
  const moq = snapshot.moq ?? {};
  element("moq-status").textContent = moq.connected ? "CONECTADO" : "ESPERANDO";
  element("moq-relay").textContent = moq.relay ?? "—";
  element("moq-connection-id").textContent = moq.connection_id ?? "—";
  element("moq-objects").textContent = (moq.objects ?? 0).toLocaleString();
  element("moq-bytes").textContent = formatBytes(moq.bytes ?? 0);
}

function formatLatency(value) {
  return value == null ? "—" : `${value} ms`;
}

function renderLatency(snapshot) {
  const latency = snapshot.latency ?? {};
  element("latency-metric").textContent = latency.metric === "ingest_to_publish"
    ? "INGEST → PUBLISH"
    : "—";
  element("latency-samples").textContent = (latency.samples ?? 0).toLocaleString();
  element("latency-p50").textContent = formatLatency(latency.p50_ms);
  element("latency-p95").textContent = formatLatency(latency.p95_ms);
  element("latency-p99").textContent = formatLatency(latency.p99_ms);
  element("latency-max").textContent = formatLatency(latency.max_ms);
}

function renderPhases(phases) {
  element("phases").innerHTML = phases.map((phase, index) => {
    const status = safeStatus(phase.status);
    return `<article class="phase ${status}"><span class="phase-index">0${index + 1}</span><h2>${escapeHtml(phase.label)}</h2><p class="phase-note">${escapeHtml(phase.note)}</p><span class="status">${status}</span><div class="phase-metrics"><div class="metric"><span>Unidades</span><strong>${phase.items.toLocaleString()}</strong></div><div class="metric"><span>Datos</span><strong>${formatBytes(phase.bytes)}</strong></div><div class="metric"><span>Edad</span><strong>${formatAge(phase.last_activity_ms)}</strong></div></div></article>`;
  }).join("");
}

function renderTracks(tracks) {
  element("tracks").innerHTML = tracks.map(track => {
    const status = safeStatus(track.status);
    return `<article class="track ${status}"><div class="track-title"><div><span class="status">${status}</span><h3>${escapeHtml(track.name)}</h3></div><span class="track-id">TRACK ${track.track}</span></div><div class="track-data"><div class="metric"><span>Códec</span><strong>${escapeHtml(track.codec)}</strong></div><div class="metric"><span>Programa / PID</span><strong>${escapeHtml(track.program_number)} / ${escapeHtml(track.pid)}</strong></div><div class="metric"><span>Group / Object</span><strong>${escapeHtml(track.group_id)} / ${escapeHtml(track.object_id)}</strong></div><div class="metric"><span>Tipo</span><strong>${escapeHtml(track.kind)}</strong></div><div class="metric"><span>PTS</span><strong>${escapeHtml(track.pts_ns)}</strong></div><div class="metric"><span>DTS</span><strong>${escapeHtml(track.dts_ns)}</strong></div><div class="metric"><span>Objects</span><strong>${track.objects.toLocaleString()}</strong></div><div class="metric"><span>Actividad</span><strong>${formatAge(track.last_activity_ms)}</strong></div></div></article>`;
  }).join("");
}

function renderSources(sources) {
  element("sources").innerHTML = sources.length
    ? sources.map(source => {
      const status = safeStatus(source.status);
      return `<tr><td><span class="status ${status}">${status}</span></td><td>${escapeHtml(source.connection_id)}</td><td>${escapeHtml(source.peer)}</td><td>${source.packets.toLocaleString()}</td><td>${formatBytes(source.bytes)}</td><td>${formatAge(source.last_activity_ms)}</td></tr>`;
    }).join("")
    : `<tr><td class="empty" colspan="6">Esperando una fuente SRT autorizada</td></tr>`;
}

function render(snapshot) {
  element("uptime").textContent = formatTime(snapshot.uptime_ms);
  element("revision").textContent = snapshot.revision.toLocaleString();
  element("source-count").textContent = snapshot.sources.length;
  element("updated").textContent = new Date().toLocaleTimeString();
  renderPhases(snapshot.phases);
  renderScheduler(snapshot);
  renderMoq(snapshot);
  renderLatency(snapshot);
  renderTracks(snapshot.tracks);
  renderSources(snapshot.sources);
}

function setPreviewState(kind, state, label, message) {
  const status = element(`${kind}-preview-status`);
  status.className = `status ${state}`;
  status.textContent = label;
  const messageElement = element(`${kind}-preview-message`);
  messageElement.textContent = message;
  messageElement.hidden = state === "active";
}

function initializeInputPreview(config) {
  const frame = element("input-preview");
  if (!config.input_preview_url) {
    setPreviewState("input", "unavailable", "NO CONFIGURADO", "Configura un observador SRT externo para habilitar esta vista");
    return;
  }
  setPreviewState("input", "waiting", "CARGANDO", "Conectando con el observador SRT aislado");
  frame.addEventListener("load", () => {
    frame.hidden = false;
    setPreviewState("input", "active", "OBSERVADOR CARGADO", "");
  }, { once: true });
  frame.src = config.input_preview_url;
}

async function initializePlayback() {
  try {
    const response = await fetch("/api/v1/playback", { cache: "no-store" });
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    const config = await response.json();
    initializeInputPreview(config);
  } catch (_) {
    setPreviewState("input", "unavailable", "ERROR", "No se pudo leer la configuración de reproducción");
  }
}

async function refresh() {
  try {
    const response = await fetch("/api/v1/snapshot", { cache: "no-store" });
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    render(await response.json());
    document.querySelector(".live").classList.add("online");
    element("connection").textContent = "EN LÍNEA";
  } catch (_) {
    document.querySelector(".live").classList.remove("online");
    element("connection").textContent = "SIN CONEXIÓN";
  }
}

refresh();
initializePlayback();
setInterval(refresh, 1000);
