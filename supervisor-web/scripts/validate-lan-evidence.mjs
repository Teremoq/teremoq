import { createHash } from "node:crypto";
import { open } from "node:fs/promises";
import { pathToFileURL } from "node:url";

const MAX_EVIDENCE_BYTES = 65_536;
const LEVELS = new Set([1, 5, 10, 25]);
const LOAD_ERRORS = new Set([
  null,
  "configuration-invalid",
  "trust-invalid",
  "protocol-incompatible",
  "network-unreachable",
  "connection-timeout",
  "local-stream-rejected",
  "retry-exhausted",
]);
const LOAD_KEYS = [
  "active_sessions_peak", "all_active_ms", "bytes_observed", "closed_sessions", "duration_ms",
  "errors", "first_connected_ms", "last_error", "last_object_ms", "last_session_recovery_ms",
  "level", "local_stream_rejections", "measurement_status", "mode", "objects_observed",
  "phase", "reconnect_attempts", "requested_sessions", "schema_version", "session_losses",
  "session_recoveries", "source", "unavailable_measurements", "export_kind", "run_id",
  "source_commit", "started_at_utc", "ended_at_utc",
];
const PLAYER_KEYS = [
  "active_sessions_peak", "bytes_observed", "duration_ms", "frames_observed",
  "g2g_measurement_status", "g2g_p95_ms", "last_error", "last_session_recovery_ms",
  "level", "measurement_status", "mode", "objects_observed", "phase",
  "presentation_rx_to_canvas_p95_ms", "requested_sessions", "schema_version",
  "session_losses", "session_recoveries", "source", "track", "unavailable_measurements",
  "export_kind", "run_id", "source_commit", "started_at_utc", "ended_at_utc",
];

export function validateLanEvidence(value, level) {
  if (!LEVELS.has(level) || !isRecord(value)) throw new Error("evidencia inválida");
  if (level === 1) validatePlayer(value);
  else validateLoad(value, level);
  return true;
}

function validateLoad(value, level) {
  exactKeys(value, LOAD_KEYS);
  if (value.schema_version !== 1 ||
      value.source !== "local-browser-observation-user-exported" ||
      value.export_kind !== "lan-load-sessions" || !validIdentity(value) ||
      value.measurement_status !== "measured" || value.mode !== "lightweight-moq" ||
      value.level !== level || value.requested_sessions !== level || value.phase !== "closed" ||
      value.active_sessions_peak !== level ||
      !nonNegativeInteger(value.closed_sessions) || value.closed_sessions < level ||
      !nonNegativeInteger(value.objects_observed) || value.objects_observed < 1 ||
      !nonNegativeInteger(value.bytes_observed) || value.bytes_observed < 1 ||
      !nonNegativeInteger(value.local_stream_rejections) ||
      !nonNegativeInteger(value.errors) || value.errors < value.local_stream_rejections ||
      !nonNegativeInteger(value.reconnect_attempts) ||
      !nonNegativeInteger(value.first_connected_ms) ||
      !nonNegativeInteger(value.all_active_ms) || value.all_active_ms < value.first_connected_ms ||
      !nonNegativeInteger(value.last_object_ms) || value.last_object_ms < value.first_connected_ms ||
      !nonNegativeInteger(value.duration_ms) || value.duration_ms < 600_000 ||
      value.duration_ms < value.last_object_ms ||
      !nonNegativeInteger(value.session_losses) ||
      !nonNegativeInteger(value.session_recoveries) || value.session_recoveries > value.session_losses ||
      (value.session_recoveries === 0
        ? value.last_session_recovery_ms !== null
        : !nonNegativeInteger(value.last_session_recovery_ms)) ||
      !LOAD_ERRORS.has(value.last_error)) {
    throw new Error("evidencia ligera incompleta o inconsistente");
  }
  validateUnavailable(value.unavailable_measurements, true);
}

function validatePlayer(value) {
  exactKeys(value, PLAYER_KEYS);
  if (value.schema_version !== 1 ||
      value.source !== "local-browser-observation-user-exported" ||
      value.export_kind !== "lan-real-player" || !validIdentity(value) ||
      value.measurement_status !== "measured" || value.mode !== "real-player" ||
      value.level !== 1 || value.phase !== "closed" || value.requested_sessions !== 1 ||
      value.active_sessions_peak !== 1 ||
      (value.track !== 0 && value.track !== 1) ||
      !nonNegativeInteger(value.frames_observed) || value.frames_observed < 1 ||
      !nonNegativeInteger(value.objects_observed) || value.objects_observed < 1 ||
      !nonNegativeInteger(value.bytes_observed) || value.bytes_observed < 1 ||
      !nonNegativeInteger(value.duration_ms) || value.duration_ms < 600_000 ||
      typeof value.presentation_rx_to_canvas_p95_ms !== "number" ||
      !Number.isFinite(value.presentation_rx_to_canvas_p95_ms) ||
      value.presentation_rx_to_canvas_p95_ms < 0 ||
      !validG2g(value.g2g_measurement_status, value.g2g_p95_ms) ||
      !nonNegativeInteger(value.session_losses) ||
      !nonNegativeInteger(value.session_recoveries) || value.session_recoveries > value.session_losses ||
      (value.session_recoveries === 0
        ? value.last_session_recovery_ms !== null
        : !nonNegativeInteger(value.last_session_recovery_ms)) ||
      value.last_error !== null) {
    throw new Error("evidencia del player incompleta o inconsistente");
  }
  validateUnavailable(value.unavailable_measurements, false);
}

function validateUnavailable(value, lightweight) {
  if (!isRecord(value)) throw new Error("mediciones no disponibles inválidas");
  const baseKeys = [
    "authorized_viewers", "ingest_to_publish_ms", "network_subscribers",
    "quic_jitter_ms", "quic_packet_loss", "wifi_recovery_ms",
  ];
  exactKeys(value, lightweight
    ? [...baseKeys, "frames_observed", "g2g_p95_ms", "presentation_p95_ms"]
    : baseKeys);
  if (value.authorized_viewers !== "not_measured" ||
      [
        value.ingest_to_publish_ms,
        value.network_subscribers,
        value.quic_jitter_ms,
        value.quic_packet_loss,
        value.wifi_recovery_ms,
        ...(lightweight ? [value.frames_observed, value.g2g_p95_ms, value.presentation_p95_ms] : []),
      ].some((status) => status !== "not_available")) {
    throw new Error("mediciones QUIC inferidas");
  }
}

function validIdentity(value) {
  return typeof value.run_id === "string" && /^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/.test(value.run_id) &&
    typeof value.source_commit === "string" && /^[0-9a-f]{40}$/.test(value.source_commit) &&
    canonicalUtc(value.started_at_utc) && canonicalUtc(value.ended_at_utc) &&
    Date.parse(value.ended_at_utc) >= Date.parse(value.started_at_utc);
}

function canonicalUtc(value) {
  const timestamp = typeof value === "string" ? Date.parse(value) : NaN;
  return Number.isFinite(timestamp) && new Date(timestamp).toISOString() === value;
}

function validG2g(status, value) {
  return (status === "not_available" && value === null) ||
    (status === "measured" && typeof value === "number" && Number.isFinite(value) && value >= 0);
}

function exactKeys(value, keys) {
  const actual = Object.keys(value).sort();
  const expected = [...keys].sort();
  if (actual.length !== expected.length || actual.some((key, index) => key !== expected[index])) {
    throw new Error("contrato abierto");
  }
}

function nonNegativeInteger(value) {
  return Number.isSafeInteger(value) && value >= 0;
}

function isRecord(value) {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

async function readEvidence(path) {
  const handle = await open(path, "r");
  try {
    const stat = await handle.stat();
    if (!stat.isFile() || stat.size < 2 || stat.size > MAX_EVIDENCE_BYTES) {
      throw new Error("fichero de evidencia fuera de límite");
    }
    const bytes = await handle.readFile();
    if (bytes.byteLength !== stat.size) throw new Error("evidencia cambió durante la lectura");
    return bytes;
  } finally {
    await handle.close();
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const fileFlag = process.argv.indexOf("--file");
  const levelFlag = process.argv.indexOf("--level");
  const path = fileFlag >= 0 ? process.argv[fileFlag + 1] : undefined;
  const level = levelFlag >= 0 ? Number(process.argv[levelFlag + 1]) : NaN;
  if (!path || !LEVELS.has(level)) throw new Error("uso de validador inválido");
  const bytes = await readEvidence(path);
  let value;
  try { value = JSON.parse(bytes.toString("utf8")); }
  catch { throw new Error("evidencia JSON inválida"); }
  validateLanEvidence(value, level);
  process.stdout.write(`${JSON.stringify({
    status: "valid_user_export_not_attested",
    sha256: createHash("sha256").update(bytes).digest("hex"),
  })}\n`);
}
