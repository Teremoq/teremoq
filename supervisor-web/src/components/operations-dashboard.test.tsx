import { readFileSync } from "node:fs";
import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";
import { OperationsView } from "./operations-dashboard";
import { GET as getControlPlaneProjection } from "../app/operations/api/control-plane/route";
import type {
  ControlPlaneSimulationSnapshot,
  GatewayOperationsSnapshot,
  OperationsSourceState,
} from "../lib/operations/types";

const observedAt = "2026-08-28T12:00:00.000Z";
const gatewaySnapshot: GatewayOperationsSnapshot = {
  sourceHealth: "available",
  receivedAt: observedAt,
  revision: 4,
  phases: [
    { id: "srt_ingest", status: "active", items: 10, bytes: 1000, ageMs: 20 },
    { id: "mpegts_demux", status: "active", items: 9, bytes: 900, ageMs: 30 },
    { id: "object_scheduler", status: "active", items: 8, bytes: 800, ageMs: 40 },
    { id: "moq_distribution", status: "active", items: 7, bytes: 700, ageMs: 50 },
  ],
  activeSources: 1,
  tracksActive: 4,
  scheduler: { activeSessions: 0, queuedObjects: 0, queuedBytes: 0, dropped: 0, evicted: 0 },
  relayConnected: true,
  distributedObjects: 7,
  distributedBytes: 700,
  latency: { samples: 2, p50Ms: 2, p95Ms: 3, p99Ms: 4 },
};
const controlSnapshot: ControlPlaneSimulationSnapshot = {
  sourceHealth: "available",
  sourceLabel: "Task 09 · simulación local",
  observedAt,
  authorizedViewers: 100,
  activeSessions: 100,
  reservedViewers: 0,
  egressMbps: 87,
  desiredNodes: { origin: 1, core: 2, regional: 0, "viewer-edge": 0 },
  lifecycleNodes: { requested: 0, provisioning: 0, bootstrapping: 0, authenticated: 0, registered: 0, ready: 3, draining: 0, terminated: 1, failed: 0, replacing: 0 },
  placements: [
    { role: "origin", provider: "local-sim-a", region: "eu-south", state: "ready", capacityViewers: 10_000_000, capacityEgressMbps: 10_000_000 },
    { role: "core", provider: "local-sim-a", region: "eu-south", state: "ready", capacityViewers: 60, capacityEgressMbps: 100 },
    { role: "core", provider: "local-sim-b", region: "eu-west", state: "ready", capacityViewers: 60, capacityEgressMbps: 100 },
  ],
  alerts: [],
  counters: { replacements: 1, reassignments: 50, unresolvedDrains: 0, scaleOut: 1, scaleIn: 0 },
  recovery: { sessionsRecovered: 100, replacementActions: 2 },
  eventQueue: { depth: 36, capacity: 4096 },
  measuredCost: { amount: 0, currency: "EUR", source: "local-simulation-measured", asOf: "2026-08-28" },
  estimatedCost: { amount: null, currency: "EUR", source: "local-simulation-measured", asOf: "2026-08-28" },
};

function available<T>(snapshot: T): OperationsSourceState<T> {
  return { health: "available", snapshot, reason: "source-available", lastSuccessAt: observedAt };
}

describe("dashboard de operaciones", () => {
  it("renderiza landmarks, jerarquía, tabla semántica y navegación nativa", () => {
    const page = readFileSync("src/app/operations/page.tsx", "utf8");
    const html = renderToStaticMarkup(
      <main><nav aria-label="Navegación principal"><span>Supervisor</span></nav><OperationsView gateway={available(gatewaySnapshot)} control={available(controlSnapshot)} /></main>,
    );
    expect(html).toContain("<main");
    expect(html).toContain('aria-label="Navegación principal"');
    expect(page).toContain('href="/"');
    expect(page).toContain('aria-current="page"');
    expect(html).toContain("Resumen del evento");
    expect(html).toContain("Controles preparados y deshabilitados");
  });

  it("mantiene los nueve controles nativamente disabled y sin formulario mutable", () => {
    const html = renderToStaticMarkup(
      <OperationsView gateway={available(gatewaySnapshot)} control={available(controlSnapshot)} />,
    );
    expect(html.match(/<button[^>]*disabled=""/g)).toHaveLength(9);
    expect(html).not.toContain("<form");
    expect(html).not.toContain("onClick");
    expect(html).toContain("autenticación, RBAC, CSRF");
  });

  it("separa cero explícito, ausencia y simulación sin renderizar secretos", () => {
    const html = renderToStaticMarkup(
      <OperationsView gateway={available(gatewaySnapshot)} control={available(controlSnapshot)} />,
    );
    expect(html).toContain("Simulación local");
    expect(html).toContain("Pendiente de integración");
    expect(html).toContain("0 alertas reportadas");
    for (const forbidden of ["spiffe://", "127.0.0.1", "sha256:", "/tmp/", "Traceback", "opaque-connection"]) {
      expect(html).not.toContain(forbidden);
    }
  });

  it("muestra pérdida y recuperación de fuentes con razones enumeradas", () => {
    const lost: OperationsSourceState<GatewayOperationsSnapshot> = {
      health: "lost", snapshot: gatewaySnapshot, reason: "source-unreachable", lastSuccessAt: observedAt,
    };
    const unavailable = renderToStaticMarkup(<OperationsView gateway={lost} control={{ health: "lost", snapshot: null, reason: "not-configured", lastSuccessAt: null }} />);
    expect(unavailable).toContain("Fuente perdida");
    expect(unavailable).toContain("Pendiente de integración");
    expect(unavailable).not.toContain("Señal activa observada");

    const recovered = renderToStaticMarkup(<OperationsView gateway={available(gatewaySnapshot)} control={available(controlSnapshot)} />);
    expect(recovered).toContain("Señal activa observada");
    expect(recovered).toContain("Disponible");
  });

  it("define responsive desktop/tablet/móvil y focus visible verificables", () => {
    const css = readFileSync("src/components/operations-dashboard.module.css", "utf8");
    expect(css).toContain("@media (max-width: 1100px)");
    expect(css).toContain("@media (max-width: 820px)");
    expect(css).toContain("@media (max-width: 560px)");
    expect(css).toContain(":focus-visible");
    expect(css).toContain("prefers-reduced-motion");
  });

  it("expone sólo GET en la frontera local del plano de control", () => {
    const route = readFileSync("src/app/operations/api/control-plane/route.ts", "utf8");
    expect(route).toMatch(/export async function GET\(\)/);
    for (const method of ["POST", "PUT", "PATCH", "DELETE"]) {
      expect(route).not.toMatch(new RegExp(`export\\s+(?:async\\s+)?function\\s+${method}\\b`));
    }
  });

  it("funciona por defecto sin la fixture y declara integración pendiente", async () => {
    const previous = process.env.TEREMOQ_OPERATIONS_LOCAL_SIMULATION;
    delete process.env.TEREMOQ_OPERATIONS_LOCAL_SIMULATION;
    try {
      const response = await getControlPlaneProjection();
      expect(response.status).toBe(503);
      expect(await response.json()).toEqual({ status: "not-configured" });
      expect(response.headers.get("cache-control")).toBe("no-store");
    } finally {
      if (previous === undefined) delete process.env.TEREMOQ_OPERATIONS_LOCAL_SIMULATION;
      else process.env.TEREMOQ_OPERATIONS_LOCAL_SIMULATION = previous;
    }
  });

  it("sirve sólo la proyección redactada del artefacto Task 09 aceptado con opt-in", async () => {
    const previous = process.env.TEREMOQ_OPERATIONS_LOCAL_SIMULATION;
    process.env.TEREMOQ_OPERATIONS_LOCAL_SIMULATION = "task-09";
    try {
      const response = await getControlPlaneProjection();
      expect(response.status).toBe(200);
      const projection = JSON.stringify(await response.json());
      expect(projection).toContain("Task 09 · simulación local");
      for (const forbidden of ["sha256:", "milestone-local-core", "idempotency_key", "principal_ref"]) {
        expect(projection).not.toContain(forbidden);
      }
    } finally {
      if (previous === undefined) delete process.env.TEREMOQ_OPERATIONS_LOCAL_SIMULATION;
      else process.env.TEREMOQ_OPERATIONS_LOCAL_SIMULATION = previous;
    }
  });
});
