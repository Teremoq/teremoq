import { describe, expect, it } from "vitest";
import { parseControlPlaneProjection, parseTask09Report } from "./control-plane-adapter";

const digest = `sha256:${"a".repeat(64)}`;

function action(operation: "create" | "destroy", node_id: string, tier: "origin" | "core", provider: string, region: string, generation: number, reason: string, replaces_node_id?: string) {
  return {
    operation, node_id, generation, tier,
    placement: { provider, region, zone: "zone-a" }, reason,
    capacity_viewers: tier === "origin" ? 10_000_000 : 60,
    capacity_egress_mbps: tier === "origin" ? 10_000_000 : 100,
    deadline_at: 90,
    requires_drained: operation === "destroy",
    idempotency_key: digest,
    ...(replaces_node_id ? { replaces_node_id } : {}),
  };
}

function envelope(label: string, generation: number, actions: unknown[]) {
  return { label, envelope: { schema_version: 1, deployment_id: "milestone-local", partition: "eu-south", generation, image_digest: digest, config_digest: digest, actions } };
}

function validReport() {
  const origin = action("create", "node-origin", "origin", "local-sim-a", "eu-south", 1, "configured_minimum");
  const coreA = action("create", "node-core-a", "core", "local-sim-a", "eu-south", 1, "configured_minimum");
  const coreB = action("create", "node-core-b", "core", "local-sim-b", "eu-west", 2, "autoscale_out");
  const coreC = action("create", "node-core-c", "core", "local-sim-a", "eu-south", 3, "failed_node_replacement", "node-core-a");
  const deleteA = action("destroy", "node-core-a", "core", "local-sim-a", "eu-south", 1, "failed_node_cleanup");
  return {
    schema_version: 1,
    result: "pass",
    scope: "local deterministic control-plane simulation; no real video or provider capacity",
    runtime: {}, inputs: {}, bootstrap_actions: [], limitations: [], cleanup: {}, snapshot_rollback: {},
    audit_digest: digest, report_content_digest: digest,
    gate: { controller_nodes: 1, distributor_nodes: 2, larger_scenario_executed: false, origin_nodes: 1, out_of_scope_execution_floor: 1000, progressive_scenarios: [10, 25, 50, 100], viewers: 100 },
    milestone_metrics: {
      schema_version: 1, service: "teremoq-control-plane", instance_id: "control-1", generation: 4,
      controllers_configured: 1, event_queue_depth: 36, event_queue_capacity: 4096, active_sessions: 100,
      desired_nodes: { origin: 1, core: 2, regional: 0, "viewer-edge": 0 },
      lifecycle_nodes: { requested: 0, provisioning: 0, bootstrapping: 0, authenticated: 0, registered: 0, ready: 3, draining: 0, terminated: 1, failed: 0, replacing: 0 },
      counters: { drain_unresolved_total: 0, metrics_accepted_total: 5, metrics_rejected_total: 0, nodes_replaced_total: 1, scale_in_total: 0, scale_out_total: 1, sessions_reassigned_total: 50, stale_events_ignored_total: 0 },
    },
    scenarios: [10, 25, 50, 100].map((viewers) => ({
      ready_distributors: viewers === 100 ? 2 : 1, samples: 1, session_distribution: {}, viewers,
      reconcile: [{ accepted: true, actions: [], alerts: [], desired_nodes: viewers === 100 ? 2 : 1, fail_closed: false, reason: "stable", signal: { active_sessions: viewers, authorized_viewers: viewers, egress_mbps: viewers === 100 ? 87 : viewers, required_nodes: viewers === 100 ? 2 : 1, reserved_viewers: 0 } }],
    })),
    action_envelopes: [
      envelope("bootstrap", 1, [origin, coreA]),
      envelope("scenario-100-2", 2, [coreB]),
      envelope("replacement", 3, [coreC, deleteA]),
      envelope("cleanup", 4, [
        action("destroy", "node-origin", "origin", "local-sim-a", "eu-south", 4, "safe_shutdown"),
        action("destroy", "node-core-b", "core", "local-sim-b", "eu-west", 4, "safe_shutdown"),
        action("destroy", "node-core-c", "core", "local-sim-a", "eu-south", 4, "safe_shutdown"),
      ]),
    ],
    failure_recovery: { after_distribution: {}, before_distribution: {}, failed_node: "node-core-a", replacement_actions: [coreC, deleteA], sessions_recovered: 100 },
    cost: {
      billable_egress_gb: 38.88, billable_egress_mbps: 86.4, currency: "EUR", duration_hours: 1,
      egress_cost: 0, egress_per_gb: 0, estimated_cost_per_viewer_hour: 0,
      estimated_hourly_cost_at_workload: 0, estimated_total_cost: 0, external_provider_estimate: null,
      external_provider_tariff_required: true, local_measured_remote_infrastructure_cost: 0,
      maximum_hourly_cost: 0, node_and_controller_cost: 0, payload_egress_mbps: 80,
      protocol_overhead_ratio: 0.08, rate_as_of: "2026-08-28", rate_source: "local-simulation-measured",
      workload_mbps_per_viewer: 0.8,
    },
    alerts: [],
  };
}

describe("adaptador Task 09", () => {
  it("proyecta la simulación sin identidades, digests ni falsos datos cloud", () => {
    const projection = parseTask09Report(validReport(), new Date("2026-08-28T12:00:00.000Z"));
    expect(projection.authorizedViewers).toBe(100);
    expect(projection.reservedViewers).toBe(0);
    expect(projection.measuredCost.amount).toBe(0);
    expect(projection.estimatedCost.amount).toBeNull();
    expect(projection.placements).toHaveLength(3);
    const rendered = JSON.stringify(projection);
    expect(rendered).not.toContain("node-core");
    expect(rendered).not.toContain("sha256:");
    expect(rendered).not.toContain("principal");
  });

  it("rechaza versión, timestamp futuro, propiedad desconocida e inconsistencia", () => {
    const schema = validReport();
    schema.schema_version = 2;
    expect(() => parseTask09Report(schema, new Date())).toThrow();
    expect(() => parseTask09Report(validReport(), new Date("2999-01-01T00:00:00.000Z"))).toThrow();
    const unknown = validReport();
    Object.assign(unknown, { internal_error: "/private/path" });
    expect(() => parseTask09Report(unknown, new Date())).toThrow();
    const inconsistent = validReport();
    inconsistent.milestone_metrics.active_sessions = 101;
    expect(() => parseTask09Report(inconsistent, new Date())).toThrow();
  });

  it("valida de nuevo la proyección que cruza al navegador", () => {
    const projection = parseTask09Report(validReport(), new Date("2026-08-28T12:00:00.000Z"));
    expect(parseControlPlaneProjection(projection)).toEqual(projection);
    expect(() => parseControlPlaneProjection({ ...projection, local_path: "/tmp/secret" })).toThrow();
  });
});
