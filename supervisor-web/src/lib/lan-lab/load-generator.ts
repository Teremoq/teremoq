import { MoqProtocolError } from "../moqt/binary";
import {
  MoqSession,
  WebTransportTrustError,
  type SessionEvent,
} from "../moqt/session";
import type { MoqObject } from "../moqt/subgroup";
import { resolvePlayerConnection } from "../player/engine";
import { BoundedReconnect, type ReconnectClock } from "../player/reconnect";
import { PlaybackConfigurationError } from "../supervisor/api";
import {
  LAN_LOAD_SESSION_LEVELS,
  type LanLoadSessionLevel,
  type PlayerDeployment,
} from "./config";

const LOAD_TRACK = "1-video-lq";
const ATTEMPT_TIMEOUT_MS = 8_000;
const MAX_RECONNECT_ATTEMPTS_PER_CLIENT = 6;
const MAX_RECONNECT_WINDOW_MS = 30_000;

export const LAN_LOAD_LEVELS = LAN_LOAD_SESSION_LEVELS;
export type LanLoadLevel = LanLoadSessionLevel;

export type LanLoadPhase =
  | "idle"
  | "starting"
  | "active"
  | "recovering"
  | "degraded"
  | "stopping"
  | "closed"
  | "unavailable";

export type LanLoadError =
  | "configuration-invalid"
  | "trust-invalid"
  | "protocol-incompatible"
  | "network-unreachable"
  | "connection-timeout"
  | "local-stream-rejected"
  | "retry-exhausted";

export type LanLoadSnapshot = Readonly<{
  schemaVersion: 1;
  phase: LanLoadPhase;
  requested: number;
  connected: number;
  active: number;
  activeSessionsPeak: number;
  closed: number;
  objectsObserved: number;
  bytesObserved: number;
  localStreamRejections: number;
  errors: number;
  reconnectAttempts: number;
  sessionLosses: number;
  sessionRecoveries: number;
  lastSessionRecoveryMs: number | null;
  firstConnectedMs: number | null;
  allActiveMs: number | null;
  lastObjectMs: number | null;
  elapsedMs: number | null;
  lastError: LanLoadError | null;
  runId: string | null;
  sourceCommit: string | null;
  startedAtUtc: string | null;
  endedAtUtc: string | null;
}>;

type Connection = Readonly<{
  relayUrl: string;
  namespace: readonly string[];
  fingerprint: Uint8Array;
}>;

export type LanLoadSession = {
  subscribe(
    namespace: readonly string[],
    track: string,
    handler: (object: MoqObject) => void | Promise<void>,
    deliveryClass: "video",
  ): Promise<number>;
  close(code?: number, reason?: string): Promise<void>;
};

export type LanLoadConnector = (
  connection: Connection,
  onEvent: (event: SessionEvent) => void,
  signal: AbortSignal,
) => Promise<LanLoadSession>;

type SlotState = "pending" | "connecting" | "connected" | "active" | "retry-wait" | "closed";

type Slot = {
  readonly id: number;
  readonly reconnect: BoundedReconnect;
  state: SlotState;
  attempt: number;
  failedAttempt: number;
  attemptController: AbortController | null;
  timeout: number | null;
  timedOut: boolean;
  session: LanLoadSession | null;
  recoveryStartedAt: number | null;
};

const browserClock: ReconnectClock = {
  now: () => performance.now(),
  schedule: (callback, delayMs) => window.setTimeout(callback, delayMs),
  cancel: (timer) => window.clearTimeout(timer),
};

const INITIAL_SNAPSHOT: LanLoadSnapshot = Object.freeze({
  schemaVersion: 1,
  phase: "idle",
  requested: 0,
  connected: 0,
  active: 0,
  activeSessionsPeak: 0,
  closed: 0,
  objectsObserved: 0,
  bytesObserved: 0,
  localStreamRejections: 0,
  errors: 0,
  reconnectAttempts: 0,
  sessionLosses: 0,
  sessionRecoveries: 0,
  lastSessionRecoveryMs: null,
  firstConnectedMs: null,
  allActiveMs: null,
  lastObjectMs: null,
  elapsedMs: null,
  lastError: null,
  runId: null,
  sourceCommit: null,
  startedAtUtc: null,
  endedAtUtc: null,
});

export class LanLoadGenerator {
  readonly #deployment: PlayerDeployment;
  readonly #onSnapshot: (snapshot: LanLoadSnapshot) => void;
  readonly #connector: LanLoadConnector;
  readonly #clock: ReconnectClock;
  readonly #nowUtc: () => string;
  #snapshot: LanLoadSnapshot = INITIAL_SNAPSHOT;
  #slots: Slot[] = [];
  #connection: Connection | null = null;
  #runController: AbortController | null = null;
  #runStartedAt: number | null = null;
  #generation = 0;
  #inFlight = new Set<Promise<void>>();
  #stopPromise: Promise<void> | null = null;

  constructor(
    deployment: PlayerDeployment,
    onSnapshot: (snapshot: LanLoadSnapshot) => void,
    dependencies: Readonly<{
      connector?: LanLoadConnector;
      clock?: ReconnectClock;
      nowUtc?: () => string;
    }> = {},
  ) {
    this.#deployment = deployment;
    this.#onSnapshot = onSnapshot;
    this.#connector = dependencies.connector ?? connectMoqSession;
    this.#clock = dependencies.clock ?? browserClock;
    this.#nowUtc = dependencies.nowUtc ?? (() => new Date().toISOString());
  }

  get snapshot() {
    return this.#snapshot;
  }

  async start(value: unknown) {
    const requested = parseLanLoadLevel(value);
    await this.stop();

    const generation = ++this.#generation;
    this.#runController = new AbortController();
    this.#runStartedAt = this.#clock.now();
    this.#snapshot = Object.freeze({
      ...INITIAL_SNAPSHOT,
      phase: "starting",
      requested,
      elapsedMs: 0,
      runId: this.#deployment.mode === "lan-lab" ? this.#deployment.configuration?.run_id ?? null : null,
      sourceCommit: this.#deployment.mode === "lan-lab"
        ? this.#deployment.configuration?.source_commit ?? null
        : null,
      startedAtUtc: this.#nowUtc(),
      endedAtUtc: null,
    });
    this.#onSnapshot(this.#snapshot);

    if (this.#deployment.mode !== "lan-lab") {
      this.#failConfiguration();
      return this.#snapshot;
    }

    try {
      this.#connection = await resolvePlayerConnection(
        this.#deployment,
        this.#runController.signal,
      );
    } catch {
      if (generation === this.#generation) this.#failConfiguration();
      return this.#snapshot;
    }
    if (generation !== this.#generation || this.#runController.signal.aborted) {
      return this.#snapshot;
    }

    this.#slots = Array.from({ length: requested }, (_, index): Slot => ({
      id: index,
      reconnect: new BoundedReconnect(this.#clock, {
        maximumAttempts: MAX_RECONNECT_ATTEMPTS_PER_CLIENT,
        maximumElapsedMs: MAX_RECONNECT_WINDOW_MS,
        jitterSeed: 0x74657265 ^ index,
      }),
      state: "pending",
      attempt: 0,
      failedAttempt: -1,
      attemptController: null,
      timeout: null,
      timedOut: false,
      session: null,
      recoveryStartedAt: null,
    }));
    for (const slot of this.#slots) this.#startAttempt(slot, generation);
    this.#emit();
    return this.#snapshot;
  }

  stop(): Promise<void> {
    if (this.#stopPromise) return this.#stopPromise;
    if (!this.#runController && this.#slots.length === 0) return Promise.resolve();

    const slots = this.#slots;
    ++this.#generation;
    this.#runController?.abort();
    this.#runController = null;
    this.#update({ phase: "stopping" });
    for (const slot of slots) {
      slot.reconnect.cancel();
      slot.attemptController?.abort();
      this.#clearAttemptTimeout(slot);
    }

    const closeSessions = slots.map((slot) => this.#closeSession(slot));
    this.#stopPromise = Promise.allSettled([...closeSessions, ...this.#inFlight])
      .then(async () => {
        if (this.#inFlight.size > 0) {
          await Promise.allSettled([...this.#inFlight]);
        }
        for (const slot of slots) slot.state = "closed";
        this.#slots = [];
        this.#connection = null;
        this.#update({
          phase: "closed",
          connected: 0,
          active: 0,
          endedAtUtc: this.#nowUtc(),
        });
      })
      .finally(() => {
        this.#stopPromise = null;
      });
    return this.#stopPromise;
  }

  #startAttempt(slot: Slot, generation: number) {
    if (!this.#connection || !this.#runController || generation !== this.#generation) return;
    slot.attempt += 1;
    const attempt = slot.attempt;
    slot.state = "connecting";
    slot.timedOut = false;
    slot.attemptController = new AbortController();
    const abortAttempt = () => slot.attemptController?.abort();
    this.#runController.signal.addEventListener("abort", abortAttempt, { once: true });
    slot.timeout = this.#clock.schedule(() => {
      if (
        slot.attempt === attempt &&
        (slot.state === "connecting" || slot.state === "connected")
      ) {
        slot.timedOut = true;
        slot.attemptController?.abort(new DOMException("tiempo agotado", "TimeoutError"));
      }
    }, ATTEMPT_TIMEOUT_MS);

    const task = this.#connector(
      this.#connection,
      (event) => this.#handleSessionEvent(slot, attempt, generation, event),
      slot.attemptController.signal,
    )
      .then(async (session) => {
        slot.session = session;
        this.#clearAttemptTimeout(slot);
        if (
          generation !== this.#generation ||
          slot.failedAttempt === attempt ||
          this.#runController?.signal.aborted
        ) {
          await this.#closeSession(slot);
          return;
        }
        await session.subscribe(
          this.#connection!.namespace,
          LOAD_TRACK,
          (object) => this.#observeObject(slot, attempt, generation, object),
          "video",
        );
        if (
          generation !== this.#generation ||
          slot.failedAttempt === attempt ||
          this.#runController?.signal.aborted
        ) {
          await this.#closeSession(slot);
          return;
        }
        slot.state = "active";
        if (
          this.#snapshot.allActiveMs === null &&
          this.#slots.every((candidate) => candidate.state === "active")
        ) {
          this.#update({ allActiveMs: this.#elapsed() });
        }
        this.#emit();
      })
      .catch((cause: unknown) => this.#handleFailure(slot, attempt, generation, cause))
      .finally(() => {
        this.#clearAttemptTimeout(slot);
        this.#runController?.signal.removeEventListener("abort", abortAttempt);
        if (slot.attempt === attempt) slot.attemptController = null;
        this.#inFlight.delete(task);
      });
    this.#inFlight.add(task);
    this.#emit();
  }

  #handleSessionEvent(
    slot: Slot,
    attempt: number,
    generation: number,
    event: SessionEvent,
  ) {
    if (generation !== this.#generation || slot.attempt !== attempt) return;
    if (event.type === "connected") {
      slot.state = "connected";
      if (this.#snapshot.firstConnectedMs === null) {
        this.#update({ firstConnectedMs: this.#elapsed() });
      }
      this.#emit();
    } else if (event.type === "stream-dropped") {
      this.#update({
        localStreamRejections: this.#snapshot.localStreamRejections + 1,
        errors: this.#snapshot.errors + 1,
        lastError: "local-stream-rejected",
      });
    } else if (event.type === "error") {
      this.#track(this.#handleFailure(slot, attempt, generation, event.error));
    }
  }

  async #handleFailure(
    slot: Slot,
    attempt: number,
    generation: number,
    cause: unknown,
  ) {
    if (
      generation !== this.#generation ||
      slot.attempt !== attempt ||
      slot.failedAttempt === attempt
    ) return;
    slot.failedAttempt = attempt;
    const established = slot.state === "connected" || slot.state === "active";
    if (established && slot.recoveryStartedAt === null) {
      slot.recoveryStartedAt = this.#clock.now();
      this.#update({ sessionLosses: this.#snapshot.sessionLosses + 1 });
    }
    this.#clearAttemptTimeout(slot);
    slot.attemptController?.abort();
    slot.state = "retry-wait";
    this.#update({
      errors: this.#snapshot.errors + 1,
      lastError: slot.timedOut ? "connection-timeout" : classifyLoadError(cause),
    });
    await this.#closeSession(slot);
    if (generation !== this.#generation) return;

    const decision = slot.reconnect.schedule(() => this.#startAttempt(slot, generation));
    if (decision.status === "scheduled") {
      this.#update({
        phase: "recovering",
        reconnectAttempts: this.#snapshot.reconnectAttempts + 1,
      });
      this.#emit();
    } else {
      slot.state = "closed";
      this.#update({
        errors: this.#snapshot.errors + 1,
        lastError: "retry-exhausted",
      });
      this.#emit();
    }
  }

  #observeObject(slot: Slot, attempt: number, generation: number, object: MoqObject) {
    if (
      generation !== this.#generation ||
      slot.attempt !== attempt ||
      slot.state !== "active"
    ) return;
    if (slot.recoveryStartedAt !== null) {
      const recoveryMs = Math.max(0, Math.round(this.#clock.now() - slot.recoveryStartedAt));
      slot.recoveryStartedAt = null;
      this.#update({
        sessionRecoveries: this.#snapshot.sessionRecoveries + 1,
        lastSessionRecoveryMs: recoveryMs,
      });
    }
    this.#update({
      objectsObserved: this.#snapshot.objectsObserved + 1,
      bytesObserved: this.#snapshot.bytesObserved + object.payload.byteLength,
      lastObjectMs: this.#elapsed(),
    });
  }

  async #closeSession(slot: Slot) {
    const session = slot.session;
    if (!session) return;
    slot.session = null;
    await session.close(0, "cierre local").catch(() => undefined);
    this.#update({ closed: this.#snapshot.closed + 1 });
  }

  #clearAttemptTimeout(slot: Slot) {
    if (slot.timeout !== null) this.#clock.cancel(slot.timeout);
    slot.timeout = null;
  }

  #track(task: Promise<void>) {
    this.#inFlight.add(task);
    void task.finally(() => this.#inFlight.delete(task));
  }

  #failConfiguration() {
    this.#runController?.abort();
    this.#runController = null;
    this.#update({
      phase: "unavailable",
      errors: this.#snapshot.errors + 1,
      lastError: "configuration-invalid",
    });
  }

  #emit() {
    const connected = this.#slots.filter(
      (slot) => slot.state === "connected" || slot.state === "active",
    ).length;
    const active = this.#slots.filter((slot) => slot.state === "active").length;
    const permanentClosed = this.#slots.filter((slot) => slot.state === "closed").length;
    let phase = this.#snapshot.phase;
    if (active === this.#snapshot.requested && active > 0) phase = "active";
    else if (permanentClosed > 0) phase = "degraded";
    else if (this.#snapshot.reconnectAttempts > 0) phase = "recovering";
    else if (this.#snapshot.requested > 0) phase = "starting";
    this.#update({
      phase,
      connected,
      active,
      activeSessionsPeak: Math.max(this.#snapshot.activeSessionsPeak, active),
    });
  }

  #elapsed() {
    if (this.#runStartedAt === null) return null;
    return Math.max(0, Math.round(this.#clock.now() - this.#runStartedAt));
  }

  #update(patch: Partial<LanLoadSnapshot>) {
    this.#snapshot = Object.freeze({
      ...this.#snapshot,
      ...patch,
      elapsedMs: this.#elapsed(),
    });
    this.#onSnapshot(this.#snapshot);
  }
}

export function parseLanLoadLevel(value: unknown): LanLoadLevel {
  if (typeof value !== "number" || !LAN_LOAD_LEVELS.includes(value as LanLoadLevel)) {
    throw new RangeError("nivel LAN no permitido");
  }
  return value as LanLoadLevel;
}

export function exportLanLoadMetrics(snapshot: LanLoadSnapshot) {
  const measured = isCollectibleLanLoadSnapshot(snapshot);
  return Object.freeze({
    schema_version: 1,
    export_kind: "lan-load-sessions",
    source: "local-browser-observation-user-exported",
    measurement_status: measured ? "measured" : "incomplete",
    mode: "lightweight-moq",
    level: snapshot.requested,
    run_id: snapshot.runId,
    source_commit: snapshot.sourceCommit,
    started_at_utc: snapshot.startedAtUtc,
    ended_at_utc: snapshot.endedAtUtc,
    phase: snapshot.phase,
    requested_sessions: snapshot.requested,
    active_sessions_peak: snapshot.activeSessionsPeak,
    closed_sessions: snapshot.closed,
    objects_observed: snapshot.objectsObserved,
    bytes_observed: snapshot.bytesObserved,
    local_stream_rejections: snapshot.localStreamRejections,
    errors: snapshot.errors,
    reconnect_attempts: snapshot.reconnectAttempts,
    session_losses: snapshot.sessionLosses,
    session_recoveries: snapshot.sessionRecoveries,
    last_session_recovery_ms: snapshot.lastSessionRecoveryMs,
    first_connected_ms: snapshot.firstConnectedMs,
    all_active_ms: snapshot.allActiveMs,
    last_object_ms: snapshot.lastObjectMs,
    duration_ms: snapshot.elapsedMs,
    last_error: snapshot.lastError,
    unavailable_measurements: {
      quic_packet_loss: "not_available",
      quic_jitter_ms: "not_available",
      authorized_viewers: "not_measured",
      ingest_to_publish_ms: "not_available",
      network_subscribers: "not_available",
      presentation_p95_ms: "not_available",
      g2g_p95_ms: "not_available",
      wifi_recovery_ms: "not_available",
      frames_observed: "not_available",
    },
  } as const);
}

export function isCollectibleLanLoadSnapshot(snapshot: LanLoadSnapshot) {
  return snapshot.phase === "closed" &&
    LAN_LOAD_SESSION_LEVELS.includes(snapshot.requested as LanLoadLevel) &&
    snapshot.connected === 0 &&
    snapshot.active === 0 &&
    snapshot.activeSessionsPeak === snapshot.requested &&
    Number.isSafeInteger(snapshot.closed) && snapshot.closed >= snapshot.requested &&
    Number.isSafeInteger(snapshot.objectsObserved) && snapshot.objectsObserved > 0 &&
    Number.isSafeInteger(snapshot.bytesObserved) && snapshot.bytesObserved > 0 &&
    snapshot.firstConnectedMs !== null && snapshot.firstConnectedMs >= 0 &&
    snapshot.allActiveMs !== null && snapshot.allActiveMs >= snapshot.firstConnectedMs &&
    snapshot.lastObjectMs !== null && snapshot.lastObjectMs >= snapshot.firstConnectedMs &&
    snapshot.elapsedMs !== null && snapshot.elapsedMs >= 600_000 && snapshot.elapsedMs >= snapshot.lastObjectMs &&
    snapshot.runId !== null && /^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/.test(snapshot.runId) &&
    snapshot.sourceCommit !== null && /^[0-9a-f]{40}$/.test(snapshot.sourceCommit) &&
    isCanonicalUtc(snapshot.startedAtUtc) && isCanonicalUtc(snapshot.endedAtUtc) &&
    Date.parse(snapshot.endedAtUtc!) >= Date.parse(snapshot.startedAtUtc!) &&
    Number.isSafeInteger(snapshot.errors) && snapshot.errors >= snapshot.localStreamRejections &&
    Number.isSafeInteger(snapshot.reconnectAttempts) && snapshot.reconnectAttempts >= 0 &&
    Number.isSafeInteger(snapshot.sessionLosses) && snapshot.sessionLosses >= 0 &&
    Number.isSafeInteger(snapshot.sessionRecoveries) &&
    snapshot.sessionRecoveries >= 0 && snapshot.sessionRecoveries <= snapshot.sessionLosses &&
    (snapshot.sessionRecoveries === 0
      ? snapshot.lastSessionRecoveryMs === null
      : snapshot.lastSessionRecoveryMs !== null && snapshot.lastSessionRecoveryMs >= 0);
}

function isCanonicalUtc(value: string | null) {
  if (value === null) return false;
  const timestamp = Date.parse(value);
  return Number.isFinite(timestamp) && new Date(timestamp).toISOString() === value;
}

async function connectMoqSession(
  connection: Connection,
  onEvent: (event: SessionEvent) => void,
  signal: AbortSignal,
) {
  return MoqSession.connect(
    connection.relayUrl,
    connection.fingerprint,
    onEvent,
    signal,
  );
}

function classifyLoadError(cause: unknown): LanLoadError {
  if (cause instanceof WebTransportTrustError) return "trust-invalid";
  if (cause instanceof MoqProtocolError) return "protocol-incompatible";
  if (cause instanceof PlaybackConfigurationError) return "configuration-invalid";
  if (cause instanceof DOMException && cause.name === "TimeoutError") {
    return "connection-timeout";
  }
  return "network-unreachable";
}
