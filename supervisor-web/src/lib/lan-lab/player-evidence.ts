import type { PlayerSnapshot, VideoTrackId } from "../player/engine";

const MINIMUM_EVIDENCE_DURATION_MS = 600_000;

export type PlayerEvidenceContext = Readonly<{
  elapsedMs: number | null;
  runId: string | null;
  sourceCommit: string | null;
  startedAtUtc: string | null;
  endedAtUtc: string | null;
}>;

export function isCollectiblePlayerEvidence(
  snapshot: Pick<PlayerSnapshot, "phase" | "frames" | "videoObjects" | "videoBytes" | "rxToCanvasP95Ms">,
  context: PlayerEvidenceContext,
) {
  return snapshot.phase === "closed" &&
    Number.isSafeInteger(snapshot.frames) && snapshot.frames > 0 &&
    snapshot.videoObjects > 0 && snapshot.videoBytes > 0 &&
    snapshot.rxToCanvasP95Ms !== null && snapshot.rxToCanvasP95Ms >= 0 &&
    context.elapsedMs !== null && Number.isSafeInteger(context.elapsedMs) &&
    context.elapsedMs >= MINIMUM_EVIDENCE_DURATION_MS &&
    context.runId !== null && /^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/.test(context.runId) &&
    context.sourceCommit !== null && /^[0-9a-f]{40}$/.test(context.sourceCommit) &&
    isCanonicalUtc(context.startedAtUtc) && isCanonicalUtc(context.endedAtUtc) &&
    Date.parse(context.endedAtUtc!) >= Date.parse(context.startedAtUtc!);
}

export function exportPlayerEvidence(
  snapshot: Pick<
    PlayerSnapshot,
    | "phase"
    | "frames"
    | "videoObjects"
    | "videoBytes"
    | "rxToCanvasP95Ms"
    | "sourceToCanvasSamples"
    | "sourceToCanvasP95Ms"
    | "sessionLosses"
    | "sessionRecoveries"
    | "lastSessionRecoveryMs"
  >,
  track: VideoTrackId,
  context: PlayerEvidenceContext,
) {
  const measured = isCollectiblePlayerEvidence(snapshot, context);
  return Object.freeze({
    schema_version: 1,
    export_kind: "lan-real-player",
    source: "local-browser-observation-user-exported",
    measurement_status: measured ? "measured" : "incomplete",
    mode: "real-player",
    level: 1,
    run_id: context.runId,
    source_commit: context.sourceCommit,
    started_at_utc: context.startedAtUtc,
    ended_at_utc: context.endedAtUtc,
    phase: snapshot.phase,
    requested_sessions: 1,
    active_sessions_peak: snapshot.frames > 0 ? 1 : 0,
    track,
    frames_observed: snapshot.frames,
    objects_observed: snapshot.videoObjects,
    bytes_observed: snapshot.videoBytes,
    duration_ms: context.elapsedMs,
    presentation_rx_to_canvas_p95_ms: snapshot.rxToCanvasP95Ms,
    g2g_p95_ms: snapshot.sourceToCanvasSamples > 0 ? snapshot.sourceToCanvasP95Ms : null,
    g2g_measurement_status: snapshot.sourceToCanvasSamples > 0 ? "measured" : "not_available",
    session_losses: snapshot.sessionLosses,
    session_recoveries: snapshot.sessionRecoveries,
    last_session_recovery_ms: snapshot.lastSessionRecoveryMs,
    last_error: null,
    unavailable_measurements: {
      quic_packet_loss: "not_available",
      quic_jitter_ms: "not_available",
      authorized_viewers: "not_measured",
      ingest_to_publish_ms: "not_available",
      network_subscribers: "not_available",
      wifi_recovery_ms: "not_available",
    },
  } as const);
}

function isCanonicalUtc(value: string | null) {
  if (value === null) return false;
  const timestamp = Date.parse(value);
  return Number.isFinite(timestamp) && new Date(timestamp).toISOString() === value;
}
