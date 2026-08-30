import { describe, expect, it } from "vitest";
import type { SessionEvent } from "../moqt/session";
import type { MoqObject } from "../moqt/subgroup";
import type { ReconnectClock } from "../player/reconnect";
import type { PlayerDeployment } from "./config";
import {
  exportLanLoadMetrics,
  LanLoadGenerator,
  parseLanLoadLevel,
  type LanLoadConnector,
  type LanLoadSession,
} from "./load-generator";

const DEPLOYMENT: PlayerDeployment = {
  mode: "lan-lab",
  environmentLabel: "LAN LAB / NO PRODUCCIÓN",
  configurationSource: "local-environment",
  configurationStatus: "available",
  metricsStatus: "not_measured",
  operationsAvailable: false,
  configuration: {
    schema_version: 1,
    relay_url: "https://192.168.10.20:14433/watch",
    fingerprint_sha256: "a".repeat(64),
    prefix_length: 24,
    namespace: "teremoq/live",
    run_id: "lan-test-01",
    source_commit: "1".repeat(40),
  },
};

class TestClock implements ReconnectClock {
  time = 0;
  #nextId = 1;
  #timers = new Map<number, { at: number; callback: () => void }>();

  now() { return this.time; }
  schedule(callback: () => void, delayMs: number) {
    const id = this.#nextId++;
    this.#timers.set(id, { at: this.time + delayMs, callback });
    return id;
  }
  cancel(timer: number) { this.#timers.delete(timer); }
  runNext() {
    const next = [...this.#timers.entries()].sort((a, b) => a[1].at - b[1].at)[0];
    if (!next) return false;
    this.time = next[1].at;
    this.#timers.delete(next[0]);
    next[1].callback();
    return true;
  }
  get timerCount() { return this.#timers.size; }
}

class FakeSession implements LanLoadSession {
  closed = 0;
  handler: ((object: MoqObject) => void | Promise<void>) | null = null;
  subscribedTrack: string | null = null;
  subscribedNamespace: readonly string[] | null = null;

  async subscribe(
    namespace: readonly string[],
    track: string,
    handler: (object: MoqObject) => void | Promise<void>,
  ) {
    this.subscribedNamespace = namespace;
    this.subscribedTrack = track;
    this.handler = handler;
    return 1;
  }

  async close() { this.closed += 1; }
}

function successfulHarness(clock = new TestClock()) {
  const sessions: FakeSession[] = [];
  const events: Array<(event: SessionEvent) => void> = [];
  const signals: AbortSignal[] = [];
  const connector: LanLoadConnector = async (connection, onEvent, signal) => {
    expect(connection.namespace).toEqual(["teremoq", "live"]);
    expect(connection.fingerprint).toHaveLength(32);
    signals.push(signal);
    events.push(onEvent);
    const session = new FakeSession();
    sessions.push(session);
    onEvent({ type: "connected" });
    return session;
  };
  return { clock, sessions, events, signals, connector };
}

describe("generador ligero LAN", () => {
  it.each([5, 10, 25] as const)("crea exactamente %i sesiones permitidas por el banco y sólo vídeo LQ", async (level) => {
    const harness = successfulHarness();
    const generator = new LanLoadGenerator(DEPLOYMENT, () => undefined, harness);

    await generator.start(level);
    await settle();

    expect(harness.sessions).toHaveLength(level);
    expect(generator.snapshot).toMatchObject({ requested: level, connected: level, active: level });
    expect(harness.sessions.every((session) => session.subscribedTrack === "1-video-lq")).toBe(true);
    expect(harness.sessions.every(
      (session) => JSON.stringify(session.subscribedNamespace) === '["teremoq","live"]',
    )).toBe(true);
    await generator.stop();
    expect(harness.sessions.every((session) => session.closed === 1)).toBe(true);
    expect(harness.clock.timerCount).toBe(0);
  });

  it.each([0, 1, 4, 6, 24, 26, 100, "5", null, undefined])(
    "rechaza cardinalidad no permitida %s sin tocar una ejecución activa",
    async (value) => {
      const harness = successfulHarness();
      const generator = new LanLoadGenerator(DEPLOYMENT, () => undefined, harness);
      await generator.start(5);
      await settle();

      await expect(generator.start(value)).rejects.toThrow("nivel LAN no permitido");
      expect(generator.snapshot.active).toBe(5);
      expect(harness.sessions).toHaveLength(5);
      await generator.stop();
    },
  );

  it("cuenta exclusivamente Objects y bytes entregados por el callback", async () => {
    const harness = successfulHarness();
    const generator = new LanLoadGenerator(DEPLOYMENT, () => undefined, harness);
    await generator.start(5);
    await settle();

    await harness.sessions[0].handler?.(object(3));
    await harness.sessions[1].handler?.(object(7));

    expect(generator.snapshot).toMatchObject({ objectsObserved: 2, bytesObserved: 10 });
    const exported = JSON.stringify(exportLanLoadMetrics(generator.snapshot));
    expect(exported).toContain('"source":"local-browser-observation-user-exported"');
    expect(exported).toContain('"quic_packet_loss"');
    expect(exported).not.toContain("192.168");
    expect(exported).not.toContain("teremoq/live");
    expect(exported).not.toContain("aaaaaaaa");
    await generator.stop();
  });

  it("recupera una sesión tras un corte sin solaparla", async () => {
    const harness = successfulHarness();
    const generator = new LanLoadGenerator(DEPLOYMENT, () => undefined, harness);
    await generator.start(5);
    await settle();

    harness.events[0]({ type: "error", error: new Error("socket /ruta/secreta") });
    await settle();
    expect(generator.snapshot).toMatchObject({ active: 4, reconnectAttempts: 1 });
    expect(harness.sessions[0].closed).toBe(1);

    expect(harness.clock.runNext()).toBe(true);
    await settle();
    expect(harness.sessions).toHaveLength(6);
    expect(generator.snapshot).toMatchObject({ active: 5, phase: "active" });
    harness.clock.time += 50;
    await harness.sessions[5].handler?.(object(8));
    expect(generator.snapshot).toMatchObject({
      sessionLosses: 1,
      sessionRecoveries: 1,
      lastSessionRecoveryMs: expect.any(Number),
    });
    expect(JSON.stringify(exportLanLoadMetrics(generator.snapshot))).not.toContain("ruta/secreta");
    await generator.stop();
  });

  it("sólo exporta measured tras duración mínima, tráfico, pico y cleanup total", async () => {
    const harness = successfulHarness();
    const generator = new LanLoadGenerator(DEPLOYMENT, () => undefined, harness);
    await generator.start(5);
    await settle();
    await harness.sessions[0].handler?.(object(10));
    expect(exportLanLoadMetrics(generator.snapshot).measurement_status).toBe("incomplete");

    harness.clock.time = 600_000;
    await generator.stop();
    const evidence = exportLanLoadMetrics(generator.snapshot);
    expect(evidence).toMatchObject({
      measurement_status: "measured",
      requested_sessions: 5,
      active_sessions_peak: 5,
      closed_sessions: 5,
      duration_ms: 600_000,
    });
    expect(JSON.stringify(evidence)).not.toContain("authorized_clients");
  });

  it("aborta todos los handshakes pendientes y no deja timers al detener", async () => {
    const clock = new TestClock();
    const signals: AbortSignal[] = [];
    const connector: LanLoadConnector = (_connection, _onEvent, signal) => {
      signals.push(signal);
      return new Promise((_resolve, reject) => {
        signal.addEventListener("abort", () => reject(new DOMException("cancelado", "AbortError")), {
          once: true,
        });
      });
    };
    const generator = new LanLoadGenerator(DEPLOYMENT, () => undefined, { connector, clock });
    await generator.start(25);

    await generator.stop();

    expect(signals).toHaveLength(25);
    expect(signals.every((signal) => signal.aborted)).toBe(true);
    expect(clock.timerCount).toBe(0);
    expect(generator.snapshot).toMatchObject({ active: 0, connected: 0, phase: "closed" });
  });

  it("agota un presupuesto finito de recuperación por cliente", async () => {
    const clock = new TestClock();
    let calls = 0;
    const connector: LanLoadConnector = async () => {
      calls += 1;
      throw new Error("detalle interno que no se exporta");
    };
    const generator = new LanLoadGenerator(DEPLOYMENT, () => undefined, { connector, clock });
    await generator.start(5);
    await settle();

    for (let guard = 0; guard < 100 && clock.runNext(); guard += 1) {
      await settle();
    }

    expect(calls).toBe(5 * 7);
    expect(generator.snapshot).toMatchObject({ active: 0, phase: "degraded", lastError: "retry-exhausted" });
    expect(clock.timerCount).toBe(0);
    expect(JSON.stringify(exportLanLoadMetrics(generator.snapshot))).not.toContain("detalle interno");
    await generator.stop();
  });

  it("revalida la configuración y nunca consulta Gateway en modo LAN", async () => {
    const invalid: PlayerDeployment = { ...DEPLOYMENT, configurationStatus: "unavailable", configuration: null };
    let calls = 0;
    const generator = new LanLoadGenerator(invalid, () => undefined, {
      connector: async () => { calls += 1; return new FakeSession(); },
      clock: new TestClock(),
    });

    await generator.start(5);

    expect(calls).toBe(0);
    expect(generator.snapshot).toMatchObject({ phase: "unavailable", active: 0, lastError: "configuration-invalid" });
  });
});

describe("contrato de niveles LAN", () => {
  it.each([5, 10, 25] as const)("acepta %i", (level) => {
    expect(parseLanLoadLevel(level)).toBe(level);
  });
  it.each([0, 1, 6, 26, "25", NaN, Infinity])("bloquea %s", (level) => {
    expect(() => parseLanLoadLevel(level)).toThrow(RangeError);
  });
});

function object(bytes: number): MoqObject {
  return {
    trackAlias: 1,
    groupId: 0,
    subgroupId: 0,
    publisherPriority: 0,
    objectIdDelta: 0,
    streamObjectIndex: 0,
    status: null,
    payload: new Uint8Array(bytes),
  };
}

async function settle() {
  for (let index = 0; index < 12; index += 1) await Promise.resolve();
}
