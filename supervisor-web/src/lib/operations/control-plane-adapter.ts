import type { ControlPlaneSimulationSnapshot } from "./types";
import { readResponseTextLimited } from "./bounded-response";
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
const TASK_09_VIEWERS = [10, 25, 50, 100] as const;
const TASK_09_SAMPLES = [1, 1, 1, 2] as const;
const TASK_09_READY_DISTRIBUTORS = [1, 1, 1, 2] as const;
const TASK_09_REASONS = [
  ["stable"],
  ["stable"],
  ["stable"],
  ["scale_out_stability_pending", "scaled_out"],
] as const;
const TASK_09_ACTION_COUNTS = [[0], [0], [0], [0, 1]] as const;
const TASK_09_CONFIG_DIGEST = "sha256:68e94c063b6e3fb51225dd0a815b61e5e3b496d1619fadf5b509003e8be23fe6";
const TASK_09_IMAGE_DIGEST = "sha256:07265afea47294d8bac3e450fb16c8c06403e9e4b86575d5816210f76ed8dd0b";
const TASK_09_CONTENT_DIGEST = "sha256:7151edd5c0243db99616f224210c862c5316594045f0ab31a792b0b0e76e417e";
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
  zone: string;
  capacityViewers: number;
  capacityEgressMbps: number;
  deadlineAt: number;
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
  if (digest(root.report_content_digest) !== TASK_09_CONTENT_DIGEST) {
    throw new OperationsDataError("data-inconsistent");
  }

  const runtime = exact(root.runtime, [
    "python", "platform", "elapsed_ns_measured", "logical_time_seconds",
  ]);
  boundedString(runtime.python, 32);
  boundedString(runtime.platform, 512);
  integer(runtime.elapsed_ns_measured);
  integer(runtime.logical_time_seconds);

  const inputs = exact(root.inputs, [
    "config_digest", "image_digest_identifier", "provider_mode",
    "controller_replicas", "partitions",
  ]);
  const configDigest = digest(inputs.config_digest);
  const imageDigest = digest(inputs.image_digest_identifier);
  const providerMode = enumeration(inputs.provider_mode, ["simulate", "dry-run"] as const);
  const controllerReplicas = positiveInteger(inputs.controller_replicas);
  const partitions = array(inputs.partitions, 32).map((item) => boundedString(item, 63));
  if (
    partitions.length === 0 ||
    new Set(partitions).size !== partitions.length ||
    configDigest !== TASK_09_CONFIG_DIGEST ||
    imageDigest !== TASK_09_IMAGE_DIGEST ||
    providerMode !== "simulate" ||
    controllerReplicas !== 1 ||
    partitions.length !== 1 ||
    partitions[0] !== "eu-south"
  ) throw new OperationsDataError("data-inconsistent");

  const bootstrapActions = array(root.bootstrap_actions, 1024).map((item) =>
    parseRawAction(item, false),
  );
  if (bootstrapActions.length !== 2) throw new OperationsDataError("data-inconsistent");
  array(root.limitations, 32).forEach((item) => boundedString(item, 512));

  const rollback = exact(root.snapshot_rollback, [
    "initial_digest", "recovered_digest", "rollback_generation",
  ]);
  digest(rollback.initial_digest);
  digest(rollback.recovered_digest);
  positiveInteger(rollback.rollback_generation);

  const cleanup = exact(root.cleanup, [
    "actions", "active_sessions", "terminated_nodes", "local_remote_infrastructure_cost",
  ]);
  const cleanupActions = array(cleanup.actions, 3).map((item) => parseRawAction(item, false));
  if (
    cleanupActions.length !== 3 ||
    cleanupActions.some((action) =>
      action.operation !== "destroy" || action.reason !== "safe_shutdown" || !action.requiresDrained
    ) ||
    integer(cleanup.active_sessions) !== 0 ||
    integer(cleanup.terminated_nodes) !== 4 ||
    finite(cleanup.local_remote_infrastructure_cost) !== 0
  ) throw new OperationsDataError("data-inconsistent");

  const gate = exact(root.gate, [
    "controller_nodes", "distributor_nodes", "larger_scenario_executed", "origin_nodes",
    "out_of_scope_execution_floor", "progressive_scenarios", "viewers",
  ]);
  const gateViewers = integer(gate.viewers);
  const gateControllers = integer(gate.controller_nodes, 1024);
  const gateDistributors = integer(gate.distributor_nodes);
  const gateOrigins = integer(gate.origin_nodes);
  const outOfScopeFloor = integer(gate.out_of_scope_execution_floor);
  if (gate.larger_scenario_executed !== false) throw new OperationsDataError("data-inconsistent");
  const progressive = array(gate.progressive_scenarios, TASK_09_VIEWERS.length).map((item) => integer(item));
  if (
    progressive.length !== TASK_09_VIEWERS.length ||
    progressive.some((item, index) => item !== TASK_09_VIEWERS[index]) ||
    progressive.at(-1) !== gateViewers ||
    gateControllers !== 1 ||
    gateDistributors !== 2 ||
    gateOrigins !== 1 ||
    outOfScopeFloor !== 1_000
  ) {
    throw new OperationsDataError("data-inconsistent");
  }

  const metrics = exact(root.milestone_metrics, [
    "active_sessions", "controllers_configured", "counters", "desired_nodes",
    "event_queue_capacity", "event_queue_depth", "generation", "instance_id",
    "lifecycle_nodes", "schema_version", "service",
  ]);
  assertSchemaOne(metrics.schema_version);
  if (metrics.service !== "teremoq-control-plane") throw new OperationsDataError("data-invalid");
  const instanceId = boundedString(metrics.instance_id, 128);
  const metricsGeneration = positiveInteger(metrics.generation);
  const configuredControllers = positiveInteger(metrics.controllers_configured, 1024);
  if (instanceId !== "control-1" || metricsGeneration !== 4 || configuredControllers !== controllerReplicas) {
    throw new OperationsDataError("data-inconsistent");
  }
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

  const scenarios = array(root.scenarios, TASK_09_VIEWERS.length);
  if (scenarios.length !== progressive.length) throw new OperationsDataError("data-inconsistent");
  const parsedScenarios = scenarios.map((scenario, index) => parseScenario(scenario, index));
  const finalScenario = parsedScenarios.at(-1)!;
  if (
    finalScenario.viewers !== gateViewers ||
    finalScenario.activeSessions !== activeSessions ||
    finalScenario.authorizedViewers < finalScenario.activeSessions
  ) {
    throw new OperationsDataError("data-inconsistent");
  }

  const envelopes = array(root.action_envelopes, 32).map(parseEnvelope);
  const expectedLabels = ["bootstrap", "scenario-100-2", "replacement", "cleanup"];
  if (
    envelopes.length !== expectedLabels.length ||
    envelopes.some((item, index) =>
      item.label !== expectedLabels[index] ||
      item.generation !== index + 1 ||
      item.deploymentId !== "milestone-local" ||
      item.partition !== "eu-south" ||
      item.imageDigest !== TASK_09_IMAGE_DIGEST ||
      item.configDigest !== TASK_09_CONFIG_DIGEST
    ) ||
    !sameActions(bootstrapActions, envelopes[0]!.actions) ||
    !sameActions(cleanupActions, envelopes[3]!.actions)
  ) {
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
  const failedNode = boundedString(recovery.failed_node, 128);
  const beforeDistribution = parseDistribution(recovery.before_distribution, 2);
  const afterDistribution = parseDistribution(recovery.after_distribution, 2);
  const sessionsRecovered = integer(recovery.sessions_recovered);
  const parsedReplacementActions = array(recovery.replacement_actions, 2).map((item) =>
    parseRawAction(item, true),
  );
  const replacementActions = parsedReplacementActions.length;
  if (
    sessionsRecovered !== activeSessions ||
    replacementActions !== 2 ||
    Object.keys(beforeDistribution).length !== 2 ||
    Object.keys(afterDistribution).length !== 2 ||
    sumDistribution(beforeDistribution) !== sessionsRecovered ||
    sumDistribution(afterDistribution) !== sessionsRecovered ||
    !(failedNode in beforeDistribution) ||
    failedNode in afterDistribution ||
    !sameActions(parsedReplacementActions, envelopes[2]!.actions)
  ) {
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
  if (
    typeof cost.external_provider_tariff_required !== "boolean" ||
    cost.external_provider_tariff_required !== true ||
    (estimatedAmount === null) !== cost.external_provider_tariff_required
  ) {
    throw new OperationsDataError("data-inconsistent");
  }
  for (const key of [
    "billable_egress_gb", "billable_egress_mbps", "duration_hours", "egress_cost", "egress_per_gb",
    "estimated_hourly_cost_at_workload", "estimated_total_cost", "maximum_hourly_cost",
    "node_and_controller_cost", "payload_egress_mbps", "protocol_overhead_ratio",
    "workload_mbps_per_viewer",
  ] as const) finite(cost[key]);
  if (cost.estimated_cost_per_viewer_hour !== null) finite(cost.estimated_cost_per_viewer_hour);

  const alerts = array(root.alerts, 256).map(parseAlert);

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
  if (response.status === 503) {
    void response.body?.cancel("not-configured").catch(() => undefined);
    throw new Error("not-configured");
  }
  if (!response.ok) {
    void response.body?.cancel("data-invalid").catch(() => undefined);
    throw new OperationsDataError("data-invalid");
  }
  const body = await readResponseTextLimited(response, 128 * 1024);
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

function parseScenario(value: unknown, index: number) {
  const scenario = exact(value, [
    "viewers", "samples", "reconcile", "ready_distributors", "session_distribution",
  ]);
  const viewers = integer(scenario.viewers);
  const samples = integer(scenario.samples);
  const readyDistributors = integer(scenario.ready_distributors);
  const expectedSamples = TASK_09_SAMPLES[index]!;
  const expectedReady = TASK_09_READY_DISTRIBUTORS[index]!;
  if (
    viewers !== TASK_09_VIEWERS[index] ||
    samples !== expectedSamples ||
    readyDistributors !== expectedReady
  ) throw new OperationsDataError("data-inconsistent");

  const distribution = parseDistribution(scenario.session_distribution, 1024);
  if (
    Object.keys(distribution).length !== readyDistributors ||
    sumDistribution(distribution) !== viewers
  ) throw new OperationsDataError("data-inconsistent");

  const reconciles = array(scenario.reconcile, expectedSamples);
  if (reconciles.length !== samples) throw new OperationsDataError("data-inconsistent");
  const parsed = reconciles.map((raw, reconcileIndex) =>
    parseScenarioReconcile(raw, index, reconcileIndex, viewers),
  );
  return { viewers, ...parsed.at(-1)! };
}

function parseScenarioReconcile(
  value: unknown,
  scenarioIndex: number,
  reconcileIndex: number,
  viewers: number,
) {
  const reconcile = exact(value, [
    "accepted", "fail_closed", "signal", "desired_nodes", "actions", "alerts", "reason",
  ]);
  if (reconcile.accepted !== true || reconcile.fail_closed !== false) {
    throw new OperationsDataError("data-inconsistent");
  }
  integer(reconcile.desired_nodes);
  const reason = boundedString(reconcile.reason, 128);
  if (reason !== TASK_09_REASONS[scenarioIndex]![reconcileIndex]) {
    throw new OperationsDataError("data-inconsistent");
  }
  const expectedActions = TASK_09_ACTION_COUNTS[scenarioIndex]![reconcileIndex]!;
  const actions = array(reconcile.actions, expectedActions).map((item) =>
    parseRawAction(item, false),
  );
  const alerts = array(reconcile.alerts, 256).map(parseAlert);
  if (actions.length !== expectedActions || alerts.length !== 0) {
    throw new OperationsDataError("data-inconsistent");
  }
  const signal = exact(reconcile.signal, [
    "authorized_viewers", "active_sessions", "reserved_viewers", "egress_mbps", "required_nodes",
  ]);
  const activeSessions = integer(signal.active_sessions);
  const authorizedViewers = integer(signal.authorized_viewers);
  const reservedViewers = integer(signal.reserved_viewers);
  const egressMbps = integer(signal.egress_mbps);
  positiveInteger(signal.required_nodes);
  if (
    activeSessions !== viewers ||
    authorizedViewers !== viewers ||
    reservedViewers !== 0
  ) throw new OperationsDataError("data-inconsistent");
  return { activeSessions, authorizedViewers, reservedViewers, egressMbps };
}

function parseEnvelope(value: unknown) {
  const wrapper = exact(value, ["envelope", "label"]);
  const label = boundedString(wrapper.label, 64);
  const envelope = exact(wrapper.envelope, [
    "schema_version", "deployment_id", "partition", "generation", "image_digest", "config_digest", "actions",
  ]);
  assertSchemaOne(envelope.schema_version);
  const deploymentId = boundedString(envelope.deployment_id, 63);
  const partition = boundedString(envelope.partition, 63);
  const generation = positiveInteger(envelope.generation);
  const imageDigest = digest(envelope.image_digest);
  const configDigest = digest(envelope.config_digest);
  const actions = array(envelope.actions, 1024).map((action) => parseAction(action, generation));
  if (actions.length === 0) throw new OperationsDataError("data-inconsistent");
  return { label, actions, deploymentId, partition, generation, imageDigest, configDigest };
}

function parseAction(value: unknown, envelopeGeneration: number): ParsedAction {
  const action = exact(value, [
    "operation", "node_id", "generation", "tier", "placement", "reason", "capacity_viewers",
    "capacity_egress_mbps", "deadline_at", "requires_drained", "idempotency_key",
  ], ["replaces_node_id"]);
  const operation = enumeration(action.operation, ["create", "destroy"] as const);
  const nodeId = boundedString(action.node_id, 128);
  const generation = positiveInteger(action.generation, envelopeGeneration);
  const tier = enumeration(action.tier, TIERS);
  const placement = exact(action.placement, ["provider", "region", "zone"]);
  const provider = boundedString(placement.provider, 63);
  const region = boundedString(placement.region, 63);
  const zone = boundedString(placement.zone, 63);
  const reason = enumeration(action.reason, ACTION_REASONS);
  const capacityViewers = integer(action.capacity_viewers);
  const capacityEgressMbps = integer(action.capacity_egress_mbps);
  const deadlineAt = positiveInteger(action.deadline_at);
  digest(action.idempotency_key);
  if (typeof action.requires_drained !== "boolean") throw new OperationsDataError("data-invalid");
  const replacesNodeId = action.replaces_node_id === undefined
    ? null
    : boundedString(action.replaces_node_id, 128);
  if (
    (operation === "create" && (capacityViewers === 0 || capacityEgressMbps === 0 || action.requires_drained)) ||
    (operation === "destroy" && (!action.requires_drained || replacesNodeId !== null)) ||
    operation !== operationForReason(reason) ||
    (reason === "failed_node_replacement") !== (replacesNodeId !== null)
  ) throw new OperationsDataError("data-inconsistent");
  return {
    operation, nodeId, generation, tier, provider, region, zone, capacityViewers,
    capacityEgressMbps, deadlineAt, reason, requiresDrained: action.requires_drained, replacesNodeId,
  };
}

function parseRawAction(value: unknown, replacementAllowed: boolean): ParsedAction {
  const action = exact(value, [
    "operation", "node_id", "generation", "tier", "placement", "reason", "capacity_viewers",
    "capacity_egress_mbps", "deadline_at", "requires_drained",
  ], replacementAllowed ? ["replaces_node_id"] : []);
  const operation = enumeration(action.operation, ["create", "destroy"] as const);
  const nodeId = boundedString(action.node_id, 128);
  const generation = positiveInteger(action.generation);
  const tier = enumeration(action.tier, TIERS);
  const placement = exact(action.placement, ["provider", "region", "zone"]);
  const provider = boundedString(placement.provider, 63);
  const region = boundedString(placement.region, 63);
  const zone = boundedString(placement.zone, 63);
  const reason = enumeration(action.reason, ACTION_REASONS);
  const capacityViewers = integer(action.capacity_viewers);
  const capacityEgressMbps = integer(action.capacity_egress_mbps);
  const deadlineAt = positiveInteger(action.deadline_at);
  if (typeof action.requires_drained !== "boolean") throw new OperationsDataError("data-invalid");
  const replacesNodeId = action.replaces_node_id === undefined
    ? null
    : boundedString(action.replaces_node_id, 128);
  if (
    (operation === "create" && (capacityViewers === 0 || capacityEgressMbps === 0 || action.requires_drained)) ||
    (operation === "destroy" && (!action.requires_drained || replacesNodeId !== null)) ||
    operation !== operationForReason(reason) ||
    (reason === "failed_node_replacement") !== (replacesNodeId !== null)
  ) throw new OperationsDataError("data-inconsistent");
  return {
    operation, nodeId, generation, tier, provider, region, zone, capacityViewers,
    capacityEgressMbps, deadlineAt, reason, requiresDrained: action.requires_drained, replacesNodeId,
  };
}

function parseCountRecord<const T extends readonly string[]>(value: unknown, keys: T): Record<T[number], number> {
  const result = exact(value, keys);
  return Object.fromEntries(keys.map((key) => [key, integer(result[key])])) as Record<T[number], number>;
}

function parseDistribution(value: unknown, maximum: number): Record<string, number> {
  const candidate = record(value);
  const keys = Object.keys(candidate);
  if (keys.length > maximum) throw new OperationsDataError("payload-excessive");
  const result: Record<string, number> = Object.create(null) as Record<string, number>;
  for (const key of keys) {
    boundedString(key, 128);
    result[key] = integer(candidate[key]);
  }
  return result;
}

function sumDistribution(value: Record<string, number>) {
  return Object.values(value).reduce((total, count) => total + count, 0);
}

function parseAlert(value: unknown) {
  const alert = exact(value, ["code", "severity", "partition", "reason", "observed_at"]);
  boundedString(alert.partition, 128);
  boundedString(alert.reason, 128);
  integer(alert.observed_at);
  return {
    code: enumeration(alert.code, ALERT_CODES),
    severity: enumeration(alert.severity, ["warning", "critical"] as const),
  };
}

function positiveInteger(value: unknown, maximum = Number.MAX_SAFE_INTEGER) {
  const parsed = integer(value, maximum);
  if (parsed < 1) throw new OperationsDataError("data-invalid");
  return parsed;
}

function sameActions(left: ParsedAction[], right: ParsedAction[]) {
  if (left.length !== right.length) return false;
  return left.every((action, index) => {
    const other = right[index];
    return other !== undefined &&
      action.operation === other.operation &&
      action.nodeId === other.nodeId &&
      action.generation === other.generation &&
      action.tier === other.tier &&
      action.provider === other.provider &&
      action.region === other.region &&
      action.zone === other.zone &&
      action.capacityViewers === other.capacityViewers &&
      action.capacityEgressMbps === other.capacityEgressMbps &&
      action.deadlineAt === other.deadlineAt &&
      action.reason === other.reason &&
      action.requiresDrained === other.requiresDrained &&
      action.replacesNodeId === other.replacesNodeId;
  });
}

function operationForReason(reason: ParsedAction["reason"]): ParsedAction["operation"] {
  return ["autoscale_in", "failed_node_cleanup", "safe_shutdown"].includes(reason)
    ? "destroy"
    : "create";
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
