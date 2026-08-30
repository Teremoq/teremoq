import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { validateLanEvidence } from "../../../scripts/validate-lan-evidence.mjs";

const validLoad = fixture("lightweight-level-5.valid.json");
const validPlayer = fixture("player-level-1.valid.json");
const unavailable = validLoad.unavailable_measurements as Record<string, unknown>;

describe("contrato fail-closed de evidencia trasladada por el usuario", () => {
  it.each([5, 10, 25] as const)("acepta evidencia ligera completa con nivel exacto %i", (level) => {
    expect(validateLanEvidence({
      ...validLoad,
      level,
      requested_sessions: level,
      active_sessions_peak: level,
      closed_sessions: level,
    }, level)).toBe(true);
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
    const player = validPlayer;
    expect(validateLanEvidence(player, 1)).toBe(true);
    expect(() => validateLanEvidence({ ...player, frames_observed: 0 }, 1)).toThrow();
    expect(() => validateLanEvidence({ ...player, g2g_p95_ms: 0 }, 1)).toThrow();
    expect(() => validateLanEvidence({ ...player, wifi_recovery_armed: false }, 1)).toThrow();
    expect(() => validateLanEvidence({ ...player, wifi_loss_observed: false }, 1)).toThrow();
    expect(() => validateLanEvidence({ ...player, wifi_recovery_observed: false }, 1)).toThrow();
    expect(() => validateLanEvidence({ ...player, wifi_recovery_ms: null }, 1)).toThrow();
    expect(() => validateLanEvidence({ ...player, wifi_recovery_ms: 0 }, 1)).toThrow();
    expect(() => validateLanEvidence({ ...player, wifi_recovery_ms: 180_001 }, 1)).toThrow();
    expect(() => validateLanEvidence({ ...player, forged: true }, 1)).toThrow();
  });
});

function fixture(name: string) {
  return JSON.parse(readFileSync(new URL(`fixtures/${name}`, import.meta.url), "utf8")) as
    Record<string, unknown>;
}
