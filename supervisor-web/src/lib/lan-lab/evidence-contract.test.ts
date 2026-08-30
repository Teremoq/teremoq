import { describe, expect, it } from "vitest";
import { validateLanEvidence } from "../../../scripts/validate-lan-evidence.mjs";

const unavailable = {
  quic_packet_loss: "not_available",
  quic_jitter_ms: "not_available",
  authorized_viewers: "not_measured",
  ingest_to_publish_ms: "not_available",
  network_subscribers: "not_available",
  presentation_p95_ms: "not_available",
  g2g_p95_ms: "not_available",
  wifi_recovery_ms: "not_available",
  frames_observed: "not_available",
};
const playerUnavailable = {
  quic_packet_loss: "not_available",
  quic_jitter_ms: "not_available",
  authorized_viewers: "not_measured",
  ingest_to_publish_ms: "not_available",
  network_subscribers: "not_available",
  wifi_recovery_ms: "not_available",
};
const validLoad = {
  schema_version: 1,
  export_kind: "lan-load-sessions",
  source: "local-browser-observation-user-exported",
  measurement_status: "measured",
  mode: "lightweight-moq",
  level: 5,
  run_id: "lan-test-01",
  source_commit: "1".repeat(40),
  started_at_utc: "2026-08-30T20:00:00.000Z",
  ended_at_utc: "2026-08-30T20:10:00.000Z",
  phase: "closed",
  requested_sessions: 5,
  active_sessions_peak: 5,
  closed_sessions: 5,
  objects_observed: 10,
  bytes_observed: 1000,
  local_stream_rejections: 0,
  errors: 0,
  reconnect_attempts: 0,
  session_losses: 0,
  session_recoveries: 0,
  last_session_recovery_ms: null,
  first_connected_ms: 10,
  all_active_ms: 20,
  last_object_ms: 40,
  duration_ms: 600_000,
  last_error: null,
  unavailable_measurements: unavailable,
};

describe("contrato fail-closed de evidencia trasladada por el usuario", () => {
  it("acepta evidencia ligera completa con nivel exacto", () => {
    expect(validateLanEvidence(validLoad, 5)).toBe(true);
  });

  it.each([
    ["campo desconocido", { ...validLoad, extra: true }],
    ["nivel distinto", { ...validLoad, level: 10 }],
    ["simulación", { ...validLoad, source: "simulation" }],
    ["estado incompleto", { ...validLoad, measurement_status: "incomplete" }],
    ["fase activa", { ...validLoad, phase: "active" }],
    ["objects cero", { ...validLoad, objects_observed: 0 }],
    ["bytes cero", { ...validLoad, bytes_observed: 0 }],
    ["timing inconsistente", { ...validLoad, duration_ms: 30 }],
    ["duración insuficiente", { ...validLoad, duration_ms: 599_999 }],
    ["commit ausente", { ...validLoad, source_commit: null }],
    ["timestamp imposible", { ...validLoad, ended_at_utc: "ayer" }],
    ["error interno", { ...validLoad, last_error: "C:\\secret\\token" }],
    ["jitter inventado", { ...validLoad, unavailable_measurements: { ...unavailable, quic_jitter_ms: 2 } }],
  ])("rechaza %s", (_case, value) => {
    expect(() => validateLanEvidence(value, 5)).toThrow();
  });

  it("valida el player real con contrato distinto y cerrado", () => {
    const player = {
      schema_version: 1,
      export_kind: "lan-real-player",
      source: "local-browser-observation-user-exported",
      measurement_status: "measured",
      mode: "real-player",
      level: 1,
      run_id: "lan-test-01",
      source_commit: "1".repeat(40),
      started_at_utc: "2026-08-30T20:00:00.000Z",
      ended_at_utc: "2026-08-30T20:10:00.000Z",
      phase: "closed",
      requested_sessions: 1,
      active_sessions_peak: 1,
      track: 0,
      frames_observed: 12,
      objects_observed: 20,
      bytes_observed: 2000,
      duration_ms: 600_000,
      presentation_rx_to_canvas_p95_ms: 4,
      g2g_p95_ms: null,
      g2g_measurement_status: "not_available",
      session_losses: 0,
      session_recoveries: 0,
      last_session_recovery_ms: null,
      last_error: null,
      unavailable_measurements: playerUnavailable,
    };
    expect(validateLanEvidence(player, 1)).toBe(true);
    expect(() => validateLanEvidence({ ...player, frames_observed: 0 }, 1)).toThrow();
    expect(() => validateLanEvidence({ ...player, g2g_p95_ms: 0 }, 1)).toThrow();
    expect(() => validateLanEvidence({ ...player, forged: true }, 1)).toThrow();
  });
});
