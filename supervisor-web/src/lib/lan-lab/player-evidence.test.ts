import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { exportPlayerEvidence, isCollectiblePlayerEvidence } from "./player-evidence";
import {
  INITIAL_WIFI_RECOVERY_SNAPSHOT,
  WIFI_RECOVERY_PROVENANCE,
  type WifiRecoverySnapshot,
} from "./wifi-recovery";

describe("evidencia local del player real", () => {
  it("sólo marca measured tras cierre con frames reales y tiempo observado", () => {
    expect(isCollectiblePlayerEvidence(base({ phase: "active" }), context(), measuredWifi())).toBe(false);
    expect(isCollectiblePlayerEvidence(base({ frames: 0 }), context(), measuredWifi())).toBe(false);
    expect(isCollectiblePlayerEvidence(base(), context({ elapsedMs: 599_999 }), measuredWifi())).toBe(false);
    expect(exportPlayerEvidence(base(), 0, context(), measuredWifi())).toMatchObject({
      measurement_status: "measured",
      mode: "real-player",
      level: 1,
      track: 0,
      frames_observed: 12,
      requested_sessions: 1,
      active_sessions_peak: 1,
      wifi_recovery_status: "measured",
      wifi_recovery_armed: true,
      wifi_loss_observed: true,
      wifi_recovery_observed: true,
      wifi_recovery_ms: 275,
      wifi_recovery_provenance: WIFI_RECOVERY_PROVENANCE,
    });
  });

  it("sin armado conserva Wi-Fi como no medida y no disponible", () => {
    const evidence = exportPlayerEvidence(
      base({ sessionLosses: 1, sessionRecoveries: 1, lastSessionRecoveryMs: 50 }),
      0,
      context(),
      INITIAL_WIFI_RECOVERY_SNAPSHOT,
    );
    expect(evidence).toMatchObject({
      measurement_status: "incomplete",
      wifi_recovery_status: "not_measured",
      wifi_recovery_armed: false,
      wifi_loss_observed: false,
      wifi_recovery_observed: false,
      wifi_recovery_ms: null,
      wifi_recovery_provenance: "not_available",
    });
  });

  it("declara pérdida y jitter QUIC como no disponibles", () => {
    expect(exportPlayerEvidence(base(), 1, context(), measuredWifi()).unavailable_measurements)
      .toMatchObject({ quic_packet_loss: "not_available", quic_jitter_ms: "not_available" });
  });

  it("mantiene el fixture Platform con la forma exacta del export Web", () => {
    const fixture = JSON.parse(readFileSync(
      new URL("fixtures/player-level-1.valid.json", import.meta.url),
      "utf8",
    )) as Record<string, unknown>;
    const exported = exportPlayerEvidence(base(), 0, context(), measuredWifi());
    expect(Object.keys(exported).sort()).toEqual(Object.keys(fixture).sort());
    expect(Object.keys(exported.unavailable_measurements).sort())
      .toEqual(Object.keys(fixture.unavailable_measurements as object).sort());
  });
});

function base(patch = {}) {
  return {
    phase: "closed" as const,
    frames: 12,
    videoObjects: 20,
    videoBytes: 2000,
    rxToCanvasP95Ms: 4,
    sourceToCanvasSamples: 0,
    sourceToCanvasP95Ms: null,
    sessionLosses: 1,
    sessionRecoveries: 1,
    lastSessionRecoveryMs: 300,
    ...patch,
  };
}

function measuredWifi(patch = {}): WifiRecoverySnapshot {
  return {
    status: "measured",
    armed: true,
    lossObserved: true,
    recoveryObserved: true,
    recoveryMs: 275,
    provenance: WIFI_RECOVERY_PROVENANCE,
    ...patch,
  };
}

function context(patch = {}) {
  return {
    elapsedMs: 600_000,
    runId: "lan-test-01",
    sourceCommit: "1".repeat(40),
    startedAtUtc: "2026-08-30T20:00:00.000Z",
    endedAtUtc: "2026-08-30T20:10:00.000Z",
    ...patch,
  };
}
