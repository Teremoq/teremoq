import { describe, expect, it } from "vitest";
import { exportPlayerEvidence, isCollectiblePlayerEvidence } from "./player-evidence";

describe("evidencia local del player real", () => {
  it("sólo marca measured tras cierre con frames reales y tiempo observado", () => {
    expect(isCollectiblePlayerEvidence(base({ phase: "active" }), context())).toBe(false);
    expect(isCollectiblePlayerEvidence(base({ frames: 0 }), context())).toBe(false);
    expect(isCollectiblePlayerEvidence(base(), context({ elapsedMs: 599_999 }))).toBe(false);
    expect(exportPlayerEvidence(base(), 0, context())).toMatchObject({
      measurement_status: "measured",
      mode: "real-player",
      level: 1,
      track: 0,
      frames_observed: 12,
      requested_sessions: 1,
      active_sessions_peak: 1,
    });
  });

  it("declara pérdida y jitter QUIC como no disponibles", () => {
    expect(exportPlayerEvidence(base(), 1, context()).unavailable_measurements)
      .toMatchObject({ quic_packet_loss: "not_available", quic_jitter_ms: "not_available" });
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
    sessionLosses: 0,
    sessionRecoveries: 0,
    lastSessionRecoveryMs: null,
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
