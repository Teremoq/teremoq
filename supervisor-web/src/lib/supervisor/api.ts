export type PlaybackConfiguration = {
  relayUrl: string;
  namespace: string[];
  inputPreviewUrl: string | null;
};

export type GatewaySignalSnapshot = {
  inputActive: boolean;
  sourcePackets: number;
  sourceBytes: number;
  trackGroup: number | null;
  trackObject: number | null;
  tracks: GatewayTrackSnapshot[];
  schedulerQueuedObjects: number;
  schedulerDropped: number;
  schedulerEvicted: number;
  ingestToPublishP95Ms: number | null;
};

export type GatewayTrackSnapshot = {
  id: number;
  label: string;
  status: "active" | "stale" | "waiting" | "unavailable";
  codec: string | null;
  objects: number;
};

export class PlaybackConfigurationError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "PlaybackConfigurationError";
  }
}

const TRACK_LABELS = ["VIDEO HQ", "VIDEO LQ", "AUDIO CRÍTICO", "TELEMETRÍA"] as const;

export async function loadPlaybackConfiguration(signal?: AbortSignal) {
  const response = await fetch("/gateway/api/v1/playback", {
    cache: "no-store",
    signal,
  });
  if (!response.ok) {
    throw new PlaybackConfigurationError("configuración del Gateway no disponible");
  }
  return parsePlaybackConfiguration(await response.json());
}

export async function loadGatewaySnapshot(signal?: AbortSignal) {
  const response = await fetch("/gateway/api/v1/snapshot", {
    cache: "no-store",
    signal,
  });
  if (!response.ok) {
    throw new Error(`snapshot del Gateway no disponible (${response.status})`);
  }
  return parseGatewaySnapshot(await response.json());
}

export function parsePlaybackConfiguration(value: unknown): PlaybackConfiguration {
  if (
    !isRecord(value) ||
    value.schema_version !== 1 ||
    typeof value.output_relay_url !== "string" ||
    !Array.isArray(value.namespaces) ||
    value.namespaces.length < 1 ||
    value.namespaces.length > 32 ||
    !value.namespaces.every(
      (part: unknown) => typeof part === "string" && part.length > 0 && part.length <= 255,
    ) ||
    !(
      value.input_preview_url === null ||
      typeof value.input_preview_url === "string"
    )
  ) {
    throw new PlaybackConfigurationError("respuesta /playback inválida");
  }


  const relayUrl = validateLoopbackRelayUrl(value.output_relay_url);

  const inputPreviewUrl =
    typeof value.input_preview_url === "string"
      ? validateLoopbackPreviewUrl(value.input_preview_url)
      : null;

  return {
    relayUrl,
    namespace: value.namespaces as string[],
    inputPreviewUrl: inputPreviewUrl === null ? null : localPreviewPath(inputPreviewUrl),
  };
}

export function parseGatewaySnapshot(value: unknown): GatewaySignalSnapshot {
  if (
    !isRecord(value) ||
    value.schema_version !== 1 ||
    !Array.isArray(value.phases) ||
    !Array.isArray(value.sources) ||
    !Array.isArray(value.tracks) ||
    !isRecord(value.latency)
  ) {
    throw new Error("respuesta /snapshot inválida");
  }

  const ingest = value.phases.find(
    (phase: unknown) => isRecord(phase) && phase.id === "srt_ingest",
  );
  const sources = value.sources.filter(
    (candidate: unknown) => isRecord(candidate) && candidate.status === "active",
  );
  const track = value.tracks.find(
    (candidate: unknown) => isRecord(candidate) && candidate.track === 0,
  );

  const scheduler = isRecord(value.scheduler) ? value.scheduler : {};
  const rawTracks: unknown[] = value.tracks;
  const tracks = TRACK_LABELS.map((label, id): GatewayTrackSnapshot => {
    const candidate = rawTracks.find(
      (current: unknown) => isRecord(current) && current.track === id,
    );
    if (!isRecord(candidate)) {
      return { id, label, status: "unavailable", codec: null, objects: 0 };
    }
    return {
      id,
      label,
      status: safeTrackStatus(candidate.status),
      codec:
        typeof candidate.codec === "string" && candidate.codec.length <= 32
          ? candidate.codec
          : null,
      objects: safeNonNegativeNumber(candidate.objects),
    };
  });

  return {
    inputActive: isRecord(ingest) && ingest.status === "active" && sources.length > 0,
    sourcePackets: sources.reduce(
      (total: number, source: unknown) =>
        total + (isRecord(source) ? safeNonNegativeNumber(source.packets) : 0),
      0,
    ),
    sourceBytes: sources.reduce(
      (total: number, source: unknown) =>
        total + (isRecord(source) ? safeNonNegativeNumber(source.bytes) : 0),
      0,
    ),
    trackGroup: isRecord(track) ? safeNullableInteger(track.group_id) : null,
    trackObject: isRecord(track) ? safeNullableInteger(track.object_id) : null,
    tracks,
    schedulerQueuedObjects: safeNonNegativeNumber(scheduler.queued_objects),
    schedulerDropped: safeNonNegativeNumber(scheduler.dropped),
    schedulerEvicted: safeNonNegativeNumber(scheduler.evicted),
    ingestToPublishP95Ms: safeNullableNumber(value.latency.p95_ms),
  };
}

function safeTrackStatus(value: unknown): GatewayTrackSnapshot["status"] {
  return value === "active" || value === "stale" || value === "waiting"
    ? value
    : "unavailable";
}

function validateLoopbackPreviewUrl(value: string) {
  let url: URL;
  try {
    url = new URL(value);
  } catch {
    throw new PlaybackConfigurationError("URL del observador de entrada inválida");
  }
  if (
    !["http:", "https:"].includes(url.protocol) ||
    !["127.0.0.1", "localhost", "[::1]"].includes(url.hostname)
  ) {
    throw new PlaybackConfigurationError("el observador de entrada debe permanecer en loopback");
  }
  return url.toString();
}

function validateLoopbackRelayUrl(value: string) {
  let url: URL;
  try {
    url = new URL(value);
  } catch {
    throw new PlaybackConfigurationError("URL del relay inválida");
  }
  if (
    url.protocol !== "https:" ||
    !["127.0.0.1", "localhost", "[::1]"].includes(url.hostname) ||
    url.username !== "" ||
    url.password !== ""
  ) {
    throw new PlaybackConfigurationError("el relay WebTransport debe permanecer en loopback");
  }
  return url.toString();
}

function localPreviewPath(value: string) {
  const url = new URL(value);
  const pathname = url.pathname === "/input" ? "/input/" : url.pathname;
  return `${pathname}${url.search}${url.hash}`;
}

function safeNonNegativeNumber(value: unknown) {
  return typeof value === "number" && Number.isFinite(value) && value >= 0 ? value : 0;
}

function safeNullableNumber(value: unknown) {
  return typeof value === "number" && Number.isFinite(value) && value >= 0 ? value : null;
}

function safeNullableInteger(value: unknown) {
  return typeof value === "number" && Number.isSafeInteger(value) && value >= 0
    ? value
    : null;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}
