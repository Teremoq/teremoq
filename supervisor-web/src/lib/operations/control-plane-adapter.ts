import type { ControlPlaneSimulationSnapshot } from "./types";
import {
  OperationsDataError,
  array,
  assertIsoTimestamp,
  assertSchemaOne,
  boundedString,
  enumeration,
  exact,
  finite,
  integer,
  record,
} from "./validation";

const TIERS = ["origin", "core", "regional", "viewer-edge"] as const;
const LIFECYCLES = [
  "requested", "provisioning", "bootstrapping", "authenticated", "registered",
  "ready", "draining", "terminated", "failed", "replacing",
] as const;
const ALERT_CODES = [
  "invalid_metrics_fail_closed", "node_limit_reached", "spend_limit_reached",
  "lifecycle_timeout", "node_drain_unresolved",
] as const;
const ACTION_REASONS = [
  "configured_minimum", "autoscale_out", "autoscale_in", "failed_node_replacement",
  "failed_node_cleanup", "safe_shutdown",
] as const;
const ROOT_KEYS = [
  "action_envelopes", "alerts", "audit_digest", "bootstrap_actions", "cleanup", "cost",
  "failure_recovery", "gate", "inputs", "limitations", "milestone_metrics",
  "report_content_digest", "result", "runtime", "scenarios", "schema_version", "scope",
  "snapshot_rollback",
] as const;

type ParsedAction = {
  operation: "create" | "destroy";
  nodeId: string;
  generation: number;
  tier: (typeof TIERS)[number];
  provider: string;
  region: string;
  capacityViewers: number;
  capacityEgressMbps: number;
  reason: (typeof ACTION_REASONS)[number];
  requiresDrained: boolean;
  replacesNodeId: string | null;
};

export function parseTask09Report(
  value: unknown,
  observedAt: Date,
): ControlPlaneSimulationSnapshot {
  if (!Number.isFinite(observedAt.getTime()) || observedAt.getTime() > Date.now() + 300_000) {
    throw new OperationsDataError("data-invalid");
  }
  const root = exact(value, ROOT_KEYS);
  assertSchemaOne(root.schema_version);
  if (
    root.result !== "pass" ||
    root.scope !== "local deterministic control-plane simulation; no real video or provider capacity"
  ) {
    throw new OperationsDataError("data-inconsistent");
  }
  digest(root.audit_digest);
  digest(root.report_content_digest);
  array(root.bootstrap_actions, 1024);
  array(root.limitations, 32).forEach((item) => boundedString(item, 512));
  record(root.cleanup);
  record(root.inputs);
  record(root.runtime);
  record(root.snapshot_rollback);

  const gate = exact(root.gate, [
    "controller_nodes", "distributor_nodes", "larger_scenario_executed", "origin_nodes",
    "out_of_scope_execution_floor", "progressive_scenarios", "viewers",
  ]);
  const gateViewers = integer(gate.viewers);
  integer(gate.controller_nodes, 1024);
  integer(gate.distributor_nodes);
  integer(gate.origin_nodes);
  integer(gate.out_of_scope_execution_floor);
  if (gate.larger_scenario_executed !== false) throw new OperationsDataError("data-inconsistent");
  const progressive = array(gate.progressive_scenarios, 128).map((item) => integer(item));
  if (progressive.length === 0 || progressive.at(-1) !== gateViewers) {
    throw new OperationsDataError("data-inconsistent");
  }

  const metrics = exact(root.milestone_metrics, [
    "active_sessions", "controllers_configured", "counters", "desired_nodes",
    "event_queue_capacity", "event_queue_depth", "generation", "instance_id",
    "lifecycle_nodes", "schema_version", "service",
  ]);
  assertSchemaOne(metrics.schema_version);
  if (metrics.service !== "teremoq-control-plane") throw new OperationsDataError("data-invalid");
  boundedString(metrics.instance_id, 128);
  integer(metrics.generation);
  integer(metrics.controllers_configured, 1024);
  const activeSessions = integer(metrics.active_sessions);
  const eventDepth = integer(metrics.event_queue_depth);
  const eventCapacity = integer(metrics.event_queue_capacity);
  if (eventDepth > eventCapacity) throw new OperationsDataError("data-inconsistent");
  const desiredNodes = parseCountRecord(metrics.desired_nodes, TIERS);
  const lifecycleNodes = parseCountRecord(metrics.lifecycle_nodes, LIFECYCLES);
  const counters = exact(metrics.counters, [
    "drain_unresolved_total", "metrics_accepted_total", "metrics_rejected_total",
    "nodes_replaced_total", "scale_in_total", "scale_out_total",
    "sessions_reassigned_total", "stale_events_ignored_total",
  ]);
  const replacements = integer(counters.nodes_replaced_total);
  const reassignments = integer(counters.sessions_reassigned_total);
  const unresolvedDrains = integer(counters.drain_unresolved_total);
  const scaleOut = integer(counters.scale_out_total);
  const scaleIn = integer(counters.scale_in_total);
  integer(counters.metrics_accepted_total);
  integer(counters.metrics_rejected_total);
  integer(counters.stale_events_ignored_total);

  const scenarios = array(root.scenarios, 128);
  if (scenarios.length !== progressive.length) throw new OperationsDataError("data-inconsistent");
  const finalScenario = parseFinalScenario(scenarios.at(-1));
  if (
    finalScenario.viewers !== gateViewers ||
    finalScenario.activeSessions !== activeSessions ||
    finalScenario.authorizedViewers < finalScenario.activeSessions
  ) {
    throw new OperationsDataError("data-inconsistent");
  }

  const envelopes = array(root.action_envelopes, 32).map(parseEnvelope);
  const expectedLabels = ["bootstrap", "scenario-100-2", "replacement", "cleanup"];
  if (envelopes.length !== expectedLabels.length || envelopes.some((item, index) => item.label !== expectedLabels[index])) {
    throw new OperationsDataError("data-inconsistent");
  }
  const nodes = new Map<string, ParsedAction>();
  for (const { label, actions } of envelopes) {
    if (label === "cleanup") break;
    for (const action of actions) {
      if (action.operation === "create") {
        if (nodes.has(action.nodeId)) throw new OperationsDataError("data-inconsistent");
        nodes.set(action.nodeId, action);
      } else if (!nodes.delete(action.nodeId)) {
        throw new OperationsDataError("data-inconsistent");
      }
    }
  }
  const placements = [...nodes.values()].map((action) => ({
    role: action.tier,
    provider: action.provider,
    region: action.region,
    state: "ready" as const,
    capacityViewers: action.capacityViewers,
    capacityEgressMbps: action.capacityEgressMbps,
  }));
  if (placements.length !== lifecycleNodes.ready) throw new OperationsDataError("data-inconsistent");
  for (const tier of TIERS) {
    if (placements.filter(({ role }) => role === tier).length !== desiredNodes[tier]) {
      throw new OperationsDataError("data-inconsistent");
    }
  }

  const recovery = exact(root.failure_recovery, [
    "after_distribution", "before_distribution", "failed_node", "replacement_actions", "sessions_recovered",
  ]);
  boundedString(recovery.failed_node, 128);
  const sessionsRecovered = integer(recovery.sessions_recovered);
  const replacementActions = array(recovery.replacement_actions, 32).length;
  if (sessionsRecovered !== activeSessions || replacementActions !== 2) {
    throw new OperationsDataError("data-inconsistent");
  }

  const cost = exact(root.cost, [
    "billable_egress_gb", "billable_egress_mbps", "currency", "duration_hours", "egress_cost",
    "egress_per_gb", "estimated_cost_per_viewer_hour", "estimated_hourly_cost_at_workload",
    "estimated_total_cost", "external_provider_estimate", "external_provider_tariff_required",
    "local_measured_remote_infrastructure_cost", "maximum_hourly_cost", "node_and_controller_cost",
    "payload_egress_mbps", "protocol_overhead_ratio", "rate_as_of", "rate_source",
    "workload_mbps_per_viewer",
  ]);
  const currency = boundedString(cost.currency, 8);
  const source = boundedString(cost.rate_source, 128);
  const asOf = boundedString(cost.rate_as_of, 10);
  if (!isCalendarDate(asOf) || source !== "local-simulation-measured") {
    throw new OperationsDataError("data-invalid");
  }
  const measuredAmount = finite(cost.local_measured_remote_infrastructure_cost);
  const estimatedAmount = cost.external_provider_estimate === null
    ? null
    : finite(cost.external_provider_estimate);
  if ((estimatedAmount === null) !== (cost.external_provider_tariff_required === true)) {
    throw new OperationsDataError("data-inconsistent");
  }
  for (const key of [
    "billable_egress_gb", "billable_egress_mbps", "duration_hours", "egress_cost", "egress_per_gb",
    "estimated_hourly_cost_at_workload", "estimated_total_cost", "maximum_hourly_cost",
    "node_and_controller_cost", "payload_egress_mbps", "protocol_overhead_ratio",
    "workload_mbps_per_viewer",
  ] as const) finite(cost[key]);
  if (cost.estimated_cost_per_viewer_hour !== null) finite(cost.estimated_cost_per_viewer_hour);

  const alerts = array(root.alerts, 256).map((raw) => {
    const alert = exact(raw, ["code", "severity", "partition", "reason", "observed_at"]);
    boundedString(alert.partition, 128);
    boundedString(alert.reason, 128);
    integer(alert.observed_at);
    return {
      code: enumeration(alert.code, ALERT_CODES),
      severity: enumeration(alert.severity, ["warning", "critical"] as const),
    };
  });

  return {
    sourceHealth: "available",
    sourceLabel: "Task 09 · simulación local",
    observedAt: observedAt.toISOString(),
    authorizedViewers: finalScenario.authorizedViewers,
    activeSessions,
    reservedViewers: finalScenario.reservedViewers,
    egressMbps: finalScenario.egressMbps,
    desiredNodes,
    lifecycleNodes,
    placements,
    alerts,
    counters: { replacements, reassignments, unresolvedDrains, scaleOut, scaleIn },
    recovery: { sessionsRecovered, replacementActions },
    eventQueue: { depth: eventDepth, capacity: eventCapacity },
    measuredCost: { amount: measuredAmount, currency, source, asOf },
    estimatedCost: { amount: estimatedAmount, currency, source, asOf },
  };
}

export async function loadControlPlaneSimulation(signal: AbortSignal) {
  const response = await fetch("/operations/api/control-plane", { cache: "no-store", signal });
  if (response.status === 503) throw new Error("not-configured");
  if (!response.ok) throw new OperationsDataError("data-invalid");
  const body = await response.text();
  if (new TextEncoder().encode(body).byteLength > 128 * 1024) {
    throw new OperationsDataError("payload-excessive");
  }
  let value: unknown;
  try {
    value = JSON.parse(body);
  } catch {
    throw new OperationsDataError("data-invalid");
  }
  return parseControlPlaneProjection(value);
}

export function parseControlPlaneProjection(value: unknown): ControlPlaneSimulationSnapshot {
  const root = exact(value, [
    "sourceHealth", "sourceLabel", "observedAt", "authorizedViewers", "activeSessions",
    "reservedViewers", "egressMbps", "desiredNodes", "lifecycleNodes", "placements", "alerts",
    "counters", "recovery", "eventQueue", "measuredCost", "estimatedCost",
  ]);
  if (root.sourceHealth !== "available" || root.sourceLabel !== "Task 09 · simulación local") {
    throw new OperationsDataError("data-invalid");
  }
  const observedAt = assertIsoTimestamp(root.observedAt);
  const desiredNodes = parseCountRecord(root.desiredNodes, TIERS);
  const lifecycleNodes = parseCountRecord(root.lifecycleNodes, LIFECYCLES);
  const placements = array(root.placements, 1024).map((raw) => {
    const item = exact(raw, ["role", "provider", "region", "state", "capacityViewers", "capacityEgressMbps"]);
    if (item.state !== "ready") throw new OperationsDataError("data-invalid");
    return {
      role: enumeration(item.role, TIERS),
      provider: boundedString(item.provider, 63),
      region: boundedString(item.region, 63),
      state: "ready" as const,
      capacityViewers: integer(item.capacityViewers),
      capacityEgressMbps: integer(item.capacityEgressMbps),
    };
  });
  const alerts = array(root.alerts, 256).map((raw) => {
    const item = exact(raw, ["code", "severity"]);
    return {
      code: enumeration(item.code, ALERT_CODES),
      severity: enumeration(item.severity, ["warning", "critical"] as const),
    };
  });
  const counters = exact(root.counters, ["replacements", "reassignments", "unresolvedDrains", "scaleOut", "scaleIn"]);
  const recovery = exact(root.recovery, ["sessionsRecovered", "replacementActions"]);
  const eventQueue = exact(root.eventQueue, ["depth", "capacity"]);
  const measuredCost = parseCost(root.measuredCost, false);
  const estimatedCost = parseCost(root.estimatedCost, true);
  const result: ControlPlaneSimulationSnapshot = {
    sourceHealth: "available",
    sourceLabel: "Task 09 · simulación local",
    observedAt,
    authorizedViewers: integer(root.authorizedViewers),
    activeSessions: integer(root.activeSessions),
    reservedViewers: integer(root.reservedViewers),
    egressMbps: integer(root.egressMbps),
    desiredNodes,
    lifecycleNodes,
    placements,
    alerts,
    counters: {
      replacements: integer(counters.replacements),
      reassignments: integer(counters.reassignments),
      unresolvedDrains: integer(counters.unresolvedDrains),
      scaleOut: integer(counters.scaleOut),
      scaleIn: integer(counters.scaleIn),
    },
    recovery: {
      sessionsRecovered: integer(recovery.sessionsRecovered),
      replacementActions: integer(recovery.replacementActions),
    },
    eventQueue: { depth: integer(eventQueue.depth), capacity: integer(eventQueue.capacity) },
    measuredCost,
    estimatedCost,
  };
  if (
    result.activeSessions > result.authorizedViewers + result.reservedViewers ||
    result.eventQueue.depth > result.eventQueue.capacity ||
    result.placements.length !== result.lifecycleNodes.ready
  ) throw new OperationsDataError("data-inconsistent");
  return result;
}

function parseFinalScenario(value: unknown) {
  const scenario = exact(value, ["ready_distributors", "reconcile", "samples", "session_distribution", "viewers"]);
  integer(scenario.ready_distributors);
  integer(scenario.samples);
  record(scenario.session_distribution);
  const reconciles = array(scenario.reconcile, 32);
  if (reconciles.length === 0) throw new OperationsDataError("data-inconsistent");
  const reconcile = exact(reconciles.at(-1), ["accepted", "actions", "alerts", "desired_nodes", "fail_closed", "reason", "signal"]);
  if (reconcile.accepted !== true || reconcile.fail_closed !== false) throw new OperationsDataError("data-inconsistent");
  array(reconcile.actions, 1024);
  array(reconcile.alerts, 256);
  integer(reconcile.desired_nodes);
  boundedString(reconcile.reason, 128);
  const signal = exact(reconcile.signal, ["active_sessions", "authorized_viewers", "egress_mbps", "required_nodes", "reserved_viewers"]);
  return {
    viewers: integer(scenario.viewers),
    activeSessions: integer(signal.active_sessions),
    authorizedViewers: integer(signal.authorized_viewers),
    egressMbps: integer(signal.egress_mbps),
    reservedViewers: integer(signal.reserved_viewers),
  };
}

function parseEnvelope(value: unknown) {
  const wrapper = exact(value, ["envelope", "label"]);
  const label = boundedString(wrapper.label, 64);
  const envelope = exact(wrapper.envelope, [
    "schema_version", "deployment_id", "partition", "generation", "image_digest", "config_digest", "actions",
  ]);
  assertSchemaOne(envelope.schema_version);
  boundedString(envelope.deployment_id, 63);
  boundedString(envelope.partition, 63);
  const generation = integer(envelope.generation);
  digest(envelope.image_digest);
  digest(envelope.config_digest);
  const actions = array(envelope.actions, 1024).map((action) => parseAction(action, generation));
  if (actions.length === 0) throw new OperationsDataError("data-inconsistent");
  return { label, actions };
}

function parseAction(value: unknown, envelopeGeneration: number): ParsedAction {
  const action = exact(value, [
    "operation", "node_id", "generation", "tier", "placement", "reason", "capacity_viewers",
    "capacity_egress_mbps", "deadline_at", "requires_drained", "idempotency_key",
  ], ["replaces_node_id"]);
  const operation = enumeration(action.operation, ["create", "destroy"] as const);
  const nodeId = boundedString(action.node_id, 128);
  const generation = integer(action.generation, envelopeGeneration);
  const tier = enumeration(action.tier, TIERS);
  const placement = exact(action.placement, ["provider", "region", "zone"]);
  const provider = boundedString(placement.provider, 63);
  const region = boundedString(placement.region, 63);
  boundedString(placement.zone, 63);
  const reason = enumeration(action.reason, ACTION_REASONS);
  const capacityViewers = integer(action.capacity_viewers);
  const capacityEgressMbps = integer(action.capacity_egress_mbps);
  integer(action.deadline_at);
  digest(action.idempotency_key);
  if (typeof action.requires_drained !== "boolean") throw new OperationsDataError("data-invalid");
  const replacesNodeId = action.replaces_node_id === undefined
    ? null
    : boundedString(action.replaces_node_id, 128);
  if (
    (operation === "create" && (capacityViewers === 0 || capacityEgressMbps === 0 || action.requires_drained)) ||
    (operation === "destroy" && (!action.requires_drained || replacesNodeId !== null))
  ) throw new OperationsDataError("data-inconsistent");
  return {
    operation, nodeId, generation, tier, provider, region, capacityViewers,
    capacityEgressMbps, reason, requiresDrained: action.requires_drained, replacesNodeId,
  };
}

function parseCountRecord<const T extends readonly string[]>(value: unknown, keys: T): Record<T[number], number> {
  const result = exact(value, keys);
  return Object.fromEntries(keys.map((key) => [key, integer(result[key])])) as Record<T[number], number>;
}

function parseCost(value: unknown, nullable: false): { amount: number; currency: string; source: string; asOf: string };
function parseCost(value: unknown, nullable: true): { amount: number | null; currency: string; source: string; asOf: string };
function parseCost(value: unknown, nullable: boolean) {
  const item = exact(value, ["amount", "currency", "source", "asOf"]);
  return {
    amount: item.amount === null && nullable ? null : finite(item.amount),
    currency: boundedString(item.currency, 8),
    source: boundedString(item.source, 128),
    asOf: boundedString(item.asOf, 10),
  };
}

function digest(value: unknown) {
  const candidate = boundedString(value, 71);
  if (!/^sha256:[0-9a-f]{64}$/.test(candidate)) throw new OperationsDataError("data-invalid");
  return candidate;
}

function isCalendarDate(value: string) {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(value)) return false;
  const parsed = new Date(`${value}T00:00:00.000Z`);
  return Number.isFinite(parsed.getTime()) && parsed.toISOString().startsWith(value);
}
