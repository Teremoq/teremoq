import { describe, expect, it } from "vitest";
import {
  configuredLanLoadLevel,
  lanLabRequestDecision,
  parseLanLabConfiguration,
  parseLanLabConfigurationJson,
  playerDataPolicy,
  resolvePlayerDeployment,
  supervisorRewrites,
} from "./config";

const fingerprint = "ab".repeat(32);
const validConfiguration = {
  schema_version: 1,
  relay_url: "https://192.168.10.20:14433/watch",
  fingerprint_sha256: fingerprint,
  prefix_length: 24,
  namespace: "teremoq/live",
  run_id: "lan-run-01",
  source_commit: "1".repeat(40),
} as const;

describe("modo LAN del player", () => {
  it("conserva LAB LOOPBACK y sus rewrites por defecto", () => {
    const deployment = resolvePlayerDeployment({});
    expect(deployment).toEqual({
      mode: "loopback",
      environmentLabel: "LAB LOOPBACK",
      configurationSource: "gateway-read-only",
      metricsStatus: "available",
      operationsAvailable: true,
    });
    expect(playerDataPolicy(deployment)).toEqual({
      loadGatewayPlayback: true,
      pollGatewaySnapshot: true,
      loadInputPreview: true,
      operationsAvailable: true,
      missingMetricStatus: "unavailable",
    });
    expect(supervisorRewrites({})).toEqual([
      {
        source: "/gateway/:path*",
        destination: "http://127.0.0.1:19080/:path*",
      },
      { source: "/input/", destination: "http://127.0.0.1:8889/input/" },
      {
        source: "/input/:path*",
        destination: "http://127.0.0.1:8889/input/:path*",
      },
    ]);
  });

  it("sólo habilita LAN con opt-in exacto y congela la configuración local", () => {
    expect(resolvePlayerDeployment({ TEREMOQ_LAN_LAB: "true" }).mode).toBe("loopback");
    const deployment = resolvePlayerDeployment({
      TEREMOQ_LAN_LAB: "1",
      TEREMOQ_LAN_LAB_CONFIG: JSON.stringify(validConfiguration),
    });
    expect(deployment).toMatchObject({
      mode: "lan-lab",
      configurationStatus: "available",
      metricsStatus: "not_measured",
      operationsAvailable: false,
      configuration: validConfiguration,
    });
    expect(Object.isFrozen(deployment)).toBe(true);
    if (deployment.mode === "lan-lab") {
      expect(Object.isFrozen(deployment.configuration)).toBe(true);
      expect(playerDataPolicy(deployment)).toEqual({
        loadGatewayPlayback: false,
        pollGatewaySnapshot: false,
        loadInputPreview: false,
        operationsAvailable: false,
        missingMetricStatus: "not_measured",
      });
    }
    expect(supervisorRewrites({ TEREMOQ_LAN_LAB: "1" })).toEqual([]);
  });

  it("permanece en LAN fail-closed si falta o falla la configuración", () => {
    for (const raw of [undefined, "{", JSON.stringify({ ...validConfiguration, schema_version: 2 })]) {
      expect(resolvePlayerDeployment({
        TEREMOQ_LAN_LAB: "1",
        TEREMOQ_LAN_LAB_CONFIG: raw,
      })).toMatchObject({
        mode: "lan-lab",
        configurationStatus: "unavailable",
        configuration: null,
        operationsAvailable: false,
      });
    }
  });

  it("acota el documento local antes de parsearlo", () => {
    expect(parseLanLabConfigurationJson(JSON.stringify(validConfiguration)))
      .toEqual(validConfiguration);
    expect(() => parseLanLabConfigurationJson(" ".repeat(513))).toThrow();
  });

  it.each([
    ["https://10.20.30.40:14433/watch", 8],
    ["https://172.16.1.2:14433/watch", 12],
    ["https://172.31.254.254:14433/watch", 20],
    ["https://192.168.200.10:14433/watch", 16],
    ["https://192.168.1.5:14433/watch", 30],
  ])("acepta una IPv4 RFC1918 canónica: %s/%s", (relay_url, prefix_length) => {
    expect(parseLanLabConfiguration({
      ...validConfiguration,
      relay_url,
      prefix_length,
    })).toEqual({
      ...validConfiguration,
      relay_url,
      prefix_length,
    });
  });

  it.each([
    ["DNS", "https://relay.lan:14433/watch"],
    ["IPv6", "https://[fd00::20]:14433/watch"],
    ["loopback", "https://127.0.0.1:14433/watch"],
    ["pública", "https://8.8.8.8:14433/watch"],
    ["multicast", "https://239.1.2.3:14433/watch"],
    ["link-local", "https://169.254.1.2:14433/watch"],
    ["rango CIDR", "https://192.168.1.2:14433/watch/24"],
    ["credenciales", "https://viewer:dummy@192.168.1.2:14433/watch"],
    ["query", "https://192.168.1.2:14433/watch?token=dummy"],
    ["fragment", "https://192.168.1.2:14433/watch#peer"],
    ["path", "https://192.168.1.2:14433/publish"],
    ["slash final", "https://192.168.1.2:14433/watch/"],
    ["HTTP", "http://192.168.1.2:14433/watch"],
    ["backend loopback heredado", "https://192.168.1.2:4433/watch"],
    ["puerto distinto", "https://192.168.1.2:14434/watch"],
    ["sin puerto", "https://192.168.1.2/watch"],
    ["IPv4 no canónica", "https://0300.0250.0001.0002:14433/watch"],
  ])("rechaza relay LAN con %s", (_case, relay_url) => {
    expect(() => parseLanLabConfiguration({ ...validConfiguration, relay_url })).toThrow();
  });

  it.each([
    ["10.0.0.0", 8],
    ["10.255.255.255", 8],
    ["172.16.0.0", 12],
    ["172.31.255.255", 12],
    ["192.168.0.0", 16],
    ["192.168.255.255", 16],
    ["192.168.1.4", 30],
    ["192.168.1.7", 30],
  ])("rechaza direcciones de red/broadcast reales: %s/%s", (host, prefix_length) => {
    expect(() => parseLanLabConfiguration({
      ...validConfiguration,
      relay_url: `https://${host}:14433/watch`,
      prefix_length,
    })).toThrow();
  });

  it.each([
    7,
    31,
    24.5,
    "24",
    null,
  ])("rechaza prefix_length fuera del contrato: %s", (prefix_length) => {
    expect(() => parseLanLabConfiguration({
      ...validConfiguration,
      prefix_length,
    })).toThrow();
  });

  it("rechaza prefijos que saquen la subred fuera del bloque RFC1918", () => {
    for (const [relay_url, prefix_length] of [
      ["https://172.16.1.2:14433/watch", 8],
      ["https://192.168.1.2:14433/watch", 12],
    ] as const) {
      expect(() => parseLanLabConfiguration({
        ...validConfiguration,
        relay_url,
        prefix_length,
      })).toThrow();
    }
  });

  it("exige fingerprint, prefijo y namespace con contrato cerrado", () => {
    for (const value of [
      { schema_version: 1, relay_url: validConfiguration.relay_url },
      { ...validConfiguration, fingerprint_sha256: "ab" },
      { ...validConfiguration, fingerprint_sha256: "AB".repeat(32) },
      { ...validConfiguration, extra: true },
      { ...validConfiguration, namespace: "" },
      { ...validConfiguration, namespace: "/teremoq/live" },
      { ...validConfiguration, namespace: "teremoq//live" },
      { ...validConfiguration, namespace: "teremoq/../live" },
      { ...validConfiguration, namespace: "teremoq/live?track=0" },
      { ...validConfiguration, namespace: `teremoq/${"a".repeat(249)}` },
      { ...validConfiguration, run_id: "../run" },
      { ...validConfiguration, source_commit: "A".repeat(40) },
    ]) {
      expect(() => parseLanLabConfiguration(value)).toThrow();
    }
  });

  it("acepta el namespace MoQT real configurable dentro de sus límites", () => {
    expect(parseLanLabConfiguration({
      ...validConfiguration,
      namespace: "teremoq-lab/site_1/live.v2",
    }).namespace).toBe("teremoq-lab/site_1/live.v2");
  });

  it("bloquea dashboard, APIs y preview en LAN sin inventar fuentes", () => {
    for (const path of [
      "/gateway/api/v1/playback",
      "/gateway/api/v1/snapshot",
      "/gateway/api/v1/moq-certificate.sha256",
      "/operations",
      "/operations/api/control-plane",
      "/input/",
      "/operations%2Fapi%2Fcontrol-plane",
      "//operations",
      "/%5coperations",
    ]) {
      expect(lanLabRequestDecision("127.0.0.1:3000", path, "GET")).toBe("not-found");
    }
    expect(lanLabRequestDecision("127.0.0.1:3000", "/", "GET")).toBe("allow");
    expect(lanLabRequestDecision("127.0.0.1:3000", "/lan-load", "GET")).toBe("allow");
    expect(lanLabRequestDecision("localhost:3000", "/_next/static/app.js", "GET")).toBe("allow");
    expect(lanLabRequestDecision("localhost:3000", "/unknown", "GET")).toBe("not-found");
  });

  it("sólo traduce los niveles ligeros 5/10/25 del launcher", () => {
    expect(configuredLanLoadLevel({ TEREMOQ_LAN_LAB_LEVEL: "1" })).toBeNull();
    expect(configuredLanLoadLevel({ TEREMOQ_LAN_LAB_LEVEL: "5" })).toBe(5);
    expect(configuredLanLoadLevel({ TEREMOQ_LAN_LAB_LEVEL: "10" })).toBe(10);
    expect(configuredLanLoadLevel({ TEREMOQ_LAN_LAB_LEVEL: "25" })).toBe(25);
    for (const value of ["0", "2", "6", "26", "025", "5.0", "five", ""]) {
      expect(configuredLanLoadLevel({ TEREMOQ_LAN_LAB_LEVEL: value })).toBeNull();
    }
  });

  it("rechaza host remoto y métodos mutables aunque el bind se configure mal", () => {
    for (const host of [null, "192.168.1.50:3000", "[::1]:3000", "localhost.evil:3000"] as const) {
      expect(lanLabRequestDecision(host, "/", "GET")).toBe("misdirected");
    }
    expect(lanLabRequestDecision("localhost:3000", "/", "POST")).toBe("method-not-allowed");
  });
});
