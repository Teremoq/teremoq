export type DataProvenance =
  | "gateway-real"
  | "control-plane-simulation"
  | "cloud-future";

export type MeasurementStatus =
  | "measured"
  | "local-simulation"
  | "not-measured"
  | "not-available"
  | "pending-integration";

export type Freshness = "fresh" | "aging" | "stale" | "unknown";

export type Datum<T> = {
  value: T | null;
  status: MeasurementStatus;
  provenance: DataProvenance;
  observedAt: string | null;
  ageMs: number | null;
  freshness: Freshness;
};

export type SourceHealth = "loading" | "available" | "rejected" | "lost";

export type GatewayOperationsSnapshot = {
  receivedAt: string;
  revision: number;
  sourceHealth: "available";
  phases: Array<{
    id: "srt_ingest" | "mpegts_demux" | "object_scheduler" | "moq_distribution";
    status: "waiting" | "active" | "stale" | "unavailable";
    items: number;
    bytes: number;
    ageMs: number | null;
  }>;
  activeSources: number;
  tracksActive: number;
  scheduler: {
    activeSessions: number;
    queuedObjects: number;
    queuedBytes: number;
    dropped: number;
    evicted: number;
  };
  relayConnected: boolean;
  distributedObjects: number;
  distributedBytes: number;
  latency: {
    samples: number;
    p50Ms: number | null;
    p95Ms: number | null;
    p99Ms: number | null;
  };
};

export type ControlPlaneSimulationSnapshot = {
  sourceHealth: "available";
  sourceLabel: "Task 09 · simulación local";
  observedAt: string;
  authorizedViewers: number;
  activeSessions: number;
  reservedViewers: number;
  egressMbps: number;
  desiredNodes: Record<"origin" | "core" | "regional" | "viewer-edge", number>;
  lifecycleNodes: Record<
    | "requested"
    | "provisioning"
    | "bootstrapping"
    | "authenticated"
    | "registered"
    | "ready"
    | "draining"
    | "terminated"
    | "failed"
    | "replacing",
    number
  >;
  placements: Array<{
    role: "origin" | "core" | "regional" | "viewer-edge";
    provider: string;
    region: string;
    state: "ready";
    capacityViewers: number;
    capacityEgressMbps: number;
  }>;
  alerts: Array<{
    code: string;
    severity: "warning" | "critical";
  }>;
  counters: {
    replacements: number;
    reassignments: number;
    unresolvedDrains: number;
    scaleOut: number;
    scaleIn: number;
  };
  recovery: {
    sessionsRecovered: number;
    replacementActions: number;
  };
  eventQueue: { depth: number; capacity: number };
  measuredCost: { amount: number; currency: string; source: string; asOf: string };
  estimatedCost: {
    amount: number | null;
    currency: string;
    source: string;
    asOf: string;
  };
};

export type OperationsSourceState<T> = {
  health: SourceHealth;
  snapshot: T | null;
  reason:
    | "loading"
    | "source-available"
    | "source-unreachable"
    | "data-rejected"
    | "not-configured";
  lastSuccessAt: string | null;
};

export function datum<T>(
  value: T | null,
  status: MeasurementStatus,
  provenance: DataProvenance,
  observedAt: string | null,
  ageMs: number | null,
): Datum<T> {
  return {
    value,
    status,
    provenance,
    observedAt,
    ageMs,
    freshness: freshnessFromAge(ageMs),
  };
}

export function freshnessFromAge(ageMs: number | null): Freshness {
  if (ageMs === null) return "unknown";
  if (ageMs <= 3_000) return "fresh";
  if (ageMs <= 10_000) return "aging";
  return "stale";
}
