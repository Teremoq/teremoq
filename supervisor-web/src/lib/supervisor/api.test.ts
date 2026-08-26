import { describe, expect, it } from "vitest";
import { parseGatewaySnapshot, parsePlaybackConfiguration } from "./api";

describe("API del supervisor", () => {
  it("acepta configuración local de entrada y salida", () => {
    expect(
      parsePlaybackConfiguration({
        schema_version: 1,
        input_preview_url: "http://127.0.0.1:8889/input?muted=true",
        output_relay_url: "https://127.0.0.1:14434/watch",
        namespaces: ["teremoq", "live"],
      }),
    ).toEqual({
      inputPreviewUrl: "/input/?muted=true",
      relayUrl: "https://127.0.0.1:14434/watch",
      namespace: ["teremoq", "live"],
    });
  });

  it("rechaza un iframe remoto aunque lo entregue el Gateway", () => {
    expect(() =>
      parsePlaybackConfiguration({
        schema_version: 1,
        input_preview_url: "https://example.com/player",
        output_relay_url: "https://127.0.0.1:14434/watch",
        namespaces: ["teremoq"],
      }),
    ).toThrow(/loopback/);
  });

  it("proyecta solo las métricas reales necesarias", () => {
    expect(
      parseGatewaySnapshot({
        schema_version: 1,
        phases: [{ id: "srt_ingest", status: "active" }],
        sources: [
          { status: "active", packets: 42, bytes: 8192 },
          { status: "active", packets: 8, bytes: 2048 },
        ],
        tracks: [
          { track: 0, status: "active", codec: "h264", objects: 100, group_id: 7, object_id: 3 },
          { track: 1, status: "active", codec: "h264", objects: 50 },
          { track: 2, status: "active", codec: "aac", objects: 180 },
          { track: 3, status: "active", codec: "json", objects: 20 },
        ],
        scheduler: { queued_objects: 2, dropped: 9, evicted: 0 },
        latency: { p95_ms: 6 },
      }),
    ).toEqual({
      inputActive: true,
      sourcePackets: 50,
      sourceBytes: 10240,
      trackGroup: 7,
      trackObject: 3,
      tracks: [
        { id: 0, label: "VIDEO HQ", status: "active", codec: "h264", objects: 100 },
        { id: 1, label: "VIDEO LQ", status: "active", codec: "h264", objects: 50 },
        { id: 2, label: "AUDIO CRÍTICO", status: "active", codec: "aac", objects: 180 },
        { id: 3, label: "TELEMETRÍA", status: "active", codec: "json", objects: 20 },
      ],
      schedulerQueuedObjects: 2,
      schedulerDropped: 9,
      schedulerEvicted: 0,
      ingestToPublishP95Ms: 6,
    });
  });

  it("no inventa señal ni latencia cuando faltan datos", () => {
    expect(
      parseGatewaySnapshot({
        schema_version: 1,
        phases: [],
        sources: [],
        tracks: [],
        latency: { p95_ms: null },
      }),
    ).toMatchObject({
      inputActive: false,
      ingestToPublishP95Ms: null,
      schedulerDropped: 0,
      tracks: [
        { id: 0, status: "unavailable" },
        { id: 1, status: "unavailable" },
        { id: 2, status: "unavailable" },
        { id: 3, status: "unavailable" },
      ],
    });
  });
});
