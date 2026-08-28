import type { GatewayOperationsSnapshot } from "./types";
import { readResponseTextLimited } from "./bounded-response";
import {
  OperationsDataError,
  array,
  assertSchemaOne,
  boundedString,
  enumeration,
  exact,
  integer,
  nullableInteger,
} from "./validation";

const MAX_GATEWAY_PAYLOAD_BYTES = 512 * 1024;
const MAX_PHASES = 8;
const MAX_SOURCES = 512;
const MAX_TRACKS = 4;
const MAX_LATENCY_SAMPLES = 4096;
const PHASE_IDS = ["srt_ingest", "mpegts_demux", "object_scheduler", "moq_distribution"] as const;
const STATUSES = ["waiting", "active", "stale", "unavailable"] as const;

const ROOT_KEYS = [
  "schema_version",
  "service",
  "revision",
  "uptime_ms",
  "phases",
  "sources",
  "tracks",
  "scheduler",
  "moq",
  "latency",
] as const;

export async function loadOperationsGatewaySnapshot(signal: AbortSignal, receivedAt = new Date()) {
  const response = await fetch("/gateway/api/v1/snapshot", { cache: "no-store", signal });
  if (!response.ok) {
    void response.body?.cancel("source-unreachable").catch(() => undefined);
    throw new Error("source-unreachable");
  }
  const body = await readResponseTextLimited(response, MAX_GATEWAY_PAYLOAD_BYTES);
  let value: unknown;
  try {
    value = JSON.parse(body);
  } catch {
    throw new OperationsDataError("data-invalid");
  }
  return parseOperationsGatewaySnapshot(value, receivedAt);
}

export function parseOperationsGatewaySnapshot(
  value: unknown,
  receivedAt = new Date(),
): GatewayOperationsSnapshot {
  if (!Number.isFinite(receivedAt.getTime())) throw new OperationsDataError("data-invalid");
  const root = exact(value, ROOT_KEYS);
  assertSchemaOne(root.schema_version);
  if (root.service !== "gateway-rs") throw new OperationsDataError("data-invalid");
  const revision = integer(root.revision);
  const uptimeMs = integer(root.uptime_ms);

  const rawPhases = array(root.phases, MAX_PHASES);
  const phases = rawPhases.map((raw) => {
    const phase = exact(raw, ["id", "label", "status", "items", "bytes", "last_activity_ms", "note"]);
    const id = enumeration(phase.id, [...PHASE_IDS, "monitor"] as const);
    boundedString(phase.label, 64);
    boundedString(phase.note, 160);
    const ageMs = nullableInteger(phase.last_activity_ms, uptimeMs);
    return {
      id,
      status: enumeration(phase.status, STATUSES),
      items: integer(phase.items),
      bytes: integer(phase.bytes),
      ageMs,
    };
  });
  if (new Set(phases.map(({ id }) => id)).size !== phases.length) {
    throw new OperationsDataError("data-inconsistent");
  }
  const monitorUnavailable =
    phases.length === 1 && phases[0]?.id === "monitor" && phases[0].status === "unavailable";
  if (!monitorUnavailable && (phases.length !== 4 || PHASE_IDS.some((id) => !phases.some((p) => p.id === id)))) {
    throw new OperationsDataError("data-inconsistent");
  }

  const sources = array(root.sources, MAX_SOURCES).map((raw) => {
    const source = exact(raw, ["connection_id", "peer", "packets", "bytes", "last_activity_ms", "status"]);
    boundedString(source.connection_id, 128);
    boundedString(source.peer, 255);
    return {
      packets: integer(source.packets),
      bytes: integer(source.bytes),
      ageMs: integer(source.last_activity_ms, uptimeMs),
      status: enumeration(source.status, STATUSES),
    };
  });

  const tracks = array(root.tracks, MAX_TRACKS).map((raw) => {
    const track = exact(raw, [
      "track", "name", "status", "codec", "program_number", "pid", "group_id", "object_id",
      "kind", "pts_ns", "dts_ns", "objects", "bytes", "last_activity_ms",
    ]);
    const id = integer(track.track, 3);
    boundedString(track.name, 64);
    if (track.codec !== null) boundedString(track.codec, 32);
    if (track.kind !== null) boundedString(track.kind, 32);
    nullableInteger(track.program_number, 65_535);
    nullableInteger(track.pid, 8_191);
    nullableInteger(track.group_id);
    nullableInteger(track.object_id);
    nullableInteger(track.pts_ns);
    nullableInteger(track.dts_ns);
    return {
      id,
      status: enumeration(track.status, STATUSES),
      objects: integer(track.objects),
      bytes: integer(track.bytes),
      ageMs: nullableInteger(track.last_activity_ms, uptimeMs),
    };
  });
  if (
    new Set(tracks.map(({ id }) => id)).size !== tracks.length ||
    (!monitorUnavailable && (tracks.length !== 4 || tracks.some(({ id }, index) => id !== index))) ||
    (monitorUnavailable && tracks.length !== 0)
  ) {
    throw new OperationsDataError("data-inconsistent");
  }

  const scheduler = exact(root.scheduler, [
    "subscribers", "queued_objects", "queued_bytes", "accepted", "accepted_bytes", "dropped", "evicted", "dequeued",
  ]);
  const schedulerValues = {
    activeSessions: integer(scheduler.subscribers),
    queuedObjects: integer(scheduler.queued_objects),
    queuedBytes: integer(scheduler.queued_bytes),
    dropped: integer(scheduler.dropped),
    evicted: integer(scheduler.evicted),
  };
  integer(scheduler.accepted);
  integer(scheduler.accepted_bytes);
  integer(scheduler.dequeued);

  const moq = exact(root.moq, ["connected", "connection_id", "relay", "objects", "bytes"]);
  if (typeof moq.connected !== "boolean") throw new OperationsDataError("data-invalid");
  if (moq.connection_id !== null) boundedString(moq.connection_id, 128);
  if (moq.relay !== null) boundedString(moq.relay, 512);
  if (moq.connected && (moq.connection_id === null || moq.relay === null)) {
    throw new OperationsDataError("data-inconsistent");
  }

  const latency = exact(root.latency, [
    "metric", "samples", "window_capacity", "p50_ms", "p95_ms", "p99_ms", "max_ms",
    "network_and_subscriber_ms", "presentation_ms", "glass_to_glass_ms",
  ]);
  if (
    (!monitorUnavailable && latency.metric !== "ingest_to_publish") ||
    (monitorUnavailable && latency.metric !== "")
  ) throw new OperationsDataError("data-invalid");
  const samples = integer(latency.samples, MAX_LATENCY_SAMPLES);
  const windowCapacity = integer(latency.window_capacity, MAX_LATENCY_SAMPLES);
  if (
    samples > windowCapacity ||
    (!monitorUnavailable && windowCapacity !== MAX_LATENCY_SAMPLES) ||
    (monitorUnavailable && windowCapacity !== 0)
  ) {
    throw new OperationsDataError("data-inconsistent");
  }
  const p50Ms = nullableInteger(latency.p50_ms);
  const p95Ms = nullableInteger(latency.p95_ms);
  const p99Ms = nullableInteger(latency.p99_ms);
  const maxMs = nullableInteger(latency.max_ms);
  for (const pending of [latency.network_and_subscriber_ms, latency.presentation_ms, latency.glass_to_glass_ms]) {
    if (pending !== null) integer(pending);
  }
  const percentiles = [p50Ms, p95Ms, p99Ms, maxMs];
  if (
    (samples === 0 && percentiles.some((item) => item !== null)) ||
    (samples > 0 && percentiles.some((item) => item === null)) ||
    (samples > 0 && !nonDecreasing(percentiles as number[]))
  ) {
    throw new OperationsDataError("data-inconsistent");
  }

  return {
    sourceHealth: "available",
    receivedAt: receivedAt.toISOString(),
    revision,
    phases: monitorUnavailable
      ? []
      : phases.map(({ id, ...phase }) => ({ id: id as (typeof PHASE_IDS)[number], ...phase })),
    activeSources: sources.filter(({ status }) => status === "active").length,
    tracksActive: tracks.filter(({ status }) => status === "active").length,
    scheduler: schedulerValues,
    relayConnected: moq.connected,
    distributedObjects: integer(moq.objects),
    distributedBytes: integer(moq.bytes),
    latency: { samples, p50Ms, p95Ms, p99Ms },
  };
}

function nonDecreasing(values: number[]) {
  return values.every((value, index) => index === 0 || value >= values[index - 1]!);
}
