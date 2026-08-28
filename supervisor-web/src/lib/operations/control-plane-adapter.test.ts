import { readFileSync } from "node:fs";
import path from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";
import {
  loadControlPlaneSimulation,
  parseControlPlaneProjection,
  parseTask09Report,
} from "./control-plane-adapter";

const ACCEPTED_REPORT = JSON.parse(
  readFileSync(path.resolve(process.cwd(), "../control-plane/reports/task-09/milestone-100.json"), "utf8"),
) as Record<string, unknown>;

function validReport() {
  return structuredClone(ACCEPTED_REPORT) as Record<string, unknown>;
}

function objectField(value: Record<string, unknown>, key: string) {
  return value[key] as Record<string, unknown>;
}

function arrayField(value: Record<string, unknown>, key: string) {
  return value[key] as Array<Record<string, unknown>>;
}

describe("adaptador Task 09", () => {
  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it("proyecta el artefacto aceptado sin identidades, digests ni falsos datos cloud", () => {
    const projection = parseTask09Report(validReport(), new Date("2026-08-28T12:00:00.000Z"));
    expect(projection.authorizedViewers).toBe(100);
    expect(projection.reservedViewers).toBe(0);
    expect(projection.measuredCost.amount).toBe(0);
    expect(projection.estimatedCost.amount).toBeNull();
    expect(projection.placements).toHaveLength(3);
    const rendered = JSON.stringify(projection);
    expect(rendered).not.toContain("milestone-local-core");
    expect(rendered).not.toContain("sha256:");
    expect(rendered).not.toContain("principal");
  });

  it("rechaza versión, timestamp futuro, propiedad superior e inconsistencia", () => {
    const schema = validReport();
    schema.schema_version = 2;
    expect(() => parseTask09Report(schema, new Date())).toThrow();
    expect(() => parseTask09Report(validReport(), new Date("2999-01-01T00:00:00.000Z"))).toThrow();
    const unknown = validReport();
    unknown.internal_error = "/private/path";
    expect(() => parseTask09Report(unknown, new Date())).toThrow();
    const inconsistent = validReport();
    objectField(inconsistent, "milestone_metrics").active_sessions = 101;
    expect(() => parseTask09Report(inconsistent, new Date())).toThrow();
  });

  it("rechaza campos desconocidos o faltantes en runtime, inputs, cleanup y rollback", () => {
    for (const key of ["runtime", "inputs", "cleanup", "snapshot_rollback"]) {
      const unknown = validReport();
      objectField(unknown, key).unexpected_private_field = "secret";
      expect(() => parseTask09Report(unknown, new Date())).toThrow();
    }
    const missing = validReport();
    delete objectField(missing, "runtime").python;
    expect(() => parseTask09Report(missing, new Date())).toThrow();
  });

  it("valida todos los escenarios y rechaza uno intermedio malformado o reordenado", () => {
    const nestedUnknown = validReport();
    const secondReconcile = arrayField(arrayField(nestedUnknown, "scenarios")[1]!, "reconcile")[0]!;
    objectField(secondReconcile, "signal").internal = true;
    expect(() => parseTask09Report(nestedUnknown, new Date())).toThrow();

    const badSamples = validReport();
    arrayField(badSamples, "scenarios")[1]!.samples = 2;
    expect(() => parseTask09Report(badSamples, new Date())).toThrow();

    const reordered = validReport();
    const scenarios = arrayField(reordered, "scenarios");
    [scenarios[0], scenarios[1]] = [scenarios[1]!, scenarios[0]!];
    expect(() => parseTask09Report(reordered, new Date())).toThrow();
  });

  it("cancela una respuesta chunked del plano de control exactamente en límite + 1", async () => {
    const limit = 128 * 1024;
    let produced = 0;
    let canceled = false;
    const body = new ReadableStream({
      type: "bytes",
      pull(controller) {
        const request = controller.byobRequest;
        if (request === null) throw new Error("BYOB required");
        const view = request.view;
        if (view === null) throw new Error("BYOB view required");
        new Uint8Array(view.buffer, view.byteOffset, view.byteLength).fill(0x78);
        produced += view.byteLength;
        request.respond(view.byteLength);
      },
      cancel() {
        canceled = true;
      },
    } as UnderlyingByteSource) as ReadableStream<Uint8Array>;
    vi.stubGlobal("fetch", vi.fn(async () => ({ status: 200, ok: true, headers: new Headers(), body }) as Response));

    await expect(loadControlPlaneSimulation(new AbortController().signal)).rejects.toThrow("payload-excessive");
    expect(produced).toBe(limit + 1);
    expect(canceled).toBe(true);
  });

  it("valida de nuevo la proyección que cruza al navegador", () => {
    const projection = parseTask09Report(validReport(), new Date("2026-08-28T12:00:00.000Z"));
    expect(parseControlPlaneProjection(projection)).toEqual(projection);
    expect(() => parseControlPlaneProjection({ ...projection, local_path: "/tmp/secret" })).toThrow();
  });
});
