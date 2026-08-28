import { afterEach, describe, expect, it, vi } from "vitest";
import {
  loadOperationsGatewaySnapshot,
  parseOperationsGatewaySnapshot,
} from "./gateway-adapter";
import { freshnessFromAge } from "./types";

function validGateway() {
  return {
    schema_version: 1,
    service: "gateway-rs",
    revision: 9,
    uptime_ms: 20_000,
    phases: [
      ["srt_ingest", "SRT Ingest", "active", 10, 1_000, 100, "ingest"],
      ["mpegts_demux", "MPEG-TS Demux", "active", 8, 800, 120, "demux"],
      ["object_scheduler", "Object Scheduler", "active", 7, 700, 140, "scheduler"],
      ["moq_distribution", "MoQ Distribution", "active", 6, 600, 160, "distribution"],
    ].map(([id, label, status, items, bytes, last_activity_ms, note]) => ({
      id, label, status, items, bytes, last_activity_ms, note,
    })),
    sources: [{ connection_id: "opaque-connection", peer: "127.0.0.1:1234", packets: 10, bytes: 1_000, last_activity_ms: 100, status: "active" }],
    tracks: Array.from({ length: 4 }, (_, track) => ({
      track,
      name: `track-${track}`,
      status: "active",
      codec: track < 2 ? "h264" : track === 2 ? "aac" : "json",
      program_number: 1,
      pid: 256 + track,
      group_id: 7,
      object_id: track,
      kind: "delta",
      pts_ns: 1_000,
      dts_ns: 900,
      objects: track === 3 ? 0 : 10,
      bytes: track === 3 ? 0 : 1_000,
      last_activity_ms: 100,
    })),
    scheduler: { subscribers: 0, queued_objects: 0, queued_bytes: 0, accepted: 7, accepted_bytes: 700, dropped: 0, evicted: 0, dequeued: 7 },
    moq: { connected: true, connection_id: "opaque-moq", relay: "https://127.0.0.1:4433", objects: 6, bytes: 600 },
    latency: {
      metric: "ingest_to_publish", samples: 4, window_capacity: 4096,
      p50_ms: 2, p95_ms: 4, p99_ms: 5, max_ms: 7,
      network_and_subscriber_ms: null, presentation_ms: null, glass_to_glass_ms: null,
    },
  };
}

describe("adaptador de operaciones del Gateway", () => {
  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it("proyecta solo agregados reales y conserva ceros explícitos", () => {
    const snapshot = parseOperationsGatewaySnapshot(validGateway(), new Date("2026-08-28T12:00:00.000Z"));
    expect(snapshot.scheduler.activeSessions).toBe(0);
    expect(snapshot.scheduler.dropped).toBe(0);
    expect(snapshot.tracksActive).toBe(4);
    expect(snapshot.receivedAt).toBe("2026-08-28T12:00:00.000Z");
    expect(JSON.stringify(snapshot)).not.toContain("127.0.0.1");
    expect(JSON.stringify(snapshot)).not.toContain("opaque-connection");
  });

  it("acepta el estado unavailable contractual sin convertir sus ceros en señal", () => {
    const value = validGateway();
    Object.assign(value, { phases: [{ id: "monitor", label: "Signal Monitor", status: "unavailable", items: 0, bytes: 0, last_activity_ms: null, note: "unavailable" }] });
    value.sources = [];
    value.tracks = [];
    Object.assign(value.latency, { metric: "", samples: 0, window_capacity: 0, p50_ms: null, p95_ms: null, p99_ms: null, max_ms: null });
    expect(parseOperationsGatewaySnapshot(value).phases).toEqual([]);
  });

  it("rechaza versión, propiedades, tipos, cardinalidad y edades inválidas", () => {
    for (const mutate of [
      (value: ReturnType<typeof validGateway>) => { value.schema_version = 2; },
      (value: ReturnType<typeof validGateway>) => { Object.assign(value, { secret: "x" }); },
      (value: ReturnType<typeof validGateway>) => { value.sources[0]!.packets = -1; },
      (value: ReturnType<typeof validGateway>) => { value.sources = Array.from({ length: 513 }, () => value.sources[0]!); },
      (value: ReturnType<typeof validGateway>) => { value.sources[0]!.last_activity_ms = 20_001; },
    ]) {
      const value = validGateway();
      mutate(value);
      expect(() => parseOperationsGatewaySnapshot(value)).toThrow();
    }
  });

  it("rechaza relaciones incompatibles y percentiles imposibles", () => {
    const duplicate = validGateway();
    duplicate.tracks[1]!.track = 0;
    expect(() => parseOperationsGatewaySnapshot(duplicate)).toThrow();

    const disconnected = validGateway();
    Object.assign(disconnected.moq, { connection_id: null });
    expect(() => parseOperationsGatewaySnapshot(disconnected)).toThrow();

    const percentiles = validGateway();
    percentiles.latency.p95_ms = 1;
    expect(() => parseOperationsGatewaySnapshot(percentiles)).toThrow();
  });

  it("clasifica explícitamente un dato válido antiguo", () => {
    expect(freshnessFromAge(10_001)).toBe("stale");
  });

  it("cancela una respuesta chunked del Gateway exactamente en límite + 1", async () => {
    const limit = 512 * 1024;
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

    await expect(loadOperationsGatewaySnapshot(new AbortController().signal)).rejects.toThrow(
      "payload-excessive",
    );
    expect(produced).toBe(limit + 1);
    expect(canceled).toBe(true);
  });

  it("rechaza y cancela un body no-BYOB sin leer ningún chunk", async () => {
    let pulls = 0;
    let canceled = false;
    const body = new ReadableStream<Uint8Array>({
      pull(controller) {
        pulls += 1;
        controller.enqueue(new Uint8Array(700 * 1024));
      },
      cancel() {
        canceled = true;
      },
    }, { highWaterMark: 0 });
    vi.stubGlobal("fetch", vi.fn(async () => ({ status: 200, ok: true, headers: new Headers(), body }) as Response));

    await expect(loadOperationsGatewaySnapshot(new AbortController().signal)).rejects.toThrow(
      "data-invalid",
    );
    expect(pulls).toBe(0);
    expect(canceled).toBe(true);
  });
});
