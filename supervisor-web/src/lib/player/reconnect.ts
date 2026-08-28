export type ReconnectClock = {
  now(): number;
  schedule(callback: () => void, delayMs: number): number;
  cancel(timer: number): void;
};

export type ReconnectDecision =
  | { status: "scheduled"; attempt: number; delayMs: number }
  | { status: "exhausted" };

type ReconnectOptions = {
  baseDelayMs?: number;
  maximumDelayMs?: number;
  maximumAttempts?: number;
  maximumElapsedMs?: number;
  jitterRatio?: number;
  jitterSeed?: number;
};

const browserClock: ReconnectClock = {
  now: () => performance.now(),
  schedule: (callback, delayMs) => window.setTimeout(callback, delayMs),
  cancel: (timer) => window.clearTimeout(timer),
};

/** A single bounded retry budget. `markHealthy` is the only reset point. */
export class BoundedReconnect {
  readonly #clock: ReconnectClock;
  readonly #baseDelayMs: number;
  readonly #maximumDelayMs: number;
  readonly #maximumAttempts: number;
  readonly #maximumElapsedMs: number;
  readonly #jitterRatio: number;
  readonly #jitterSeed: number;
  #attempts = 0;
  #startedAt: number | null = null;
  #timer: number | null = null;
  #cancelled = false;

  constructor(clock: ReconnectClock = browserClock, options: ReconnectOptions = {}) {
    this.#clock = clock;
    this.#baseDelayMs = options.baseDelayMs ?? 250;
    this.#maximumDelayMs = options.maximumDelayMs ?? 2_000;
    this.#maximumAttempts = options.maximumAttempts ?? 6;
    this.#maximumElapsedMs = options.maximumElapsedMs ?? 30_000;
    this.#jitterRatio = options.jitterRatio ?? 0.2;
    this.#jitterSeed = options.jitterSeed ?? 0x74657265;
  }

  schedule(callback: (attempt: number) => void): ReconnectDecision {
    if (this.#cancelled || this.#timer !== null) return { status: "exhausted" };
    const now = this.#clock.now();
    this.#startedAt ??= now;
    const elapsed = now - this.#startedAt;
    if (this.#attempts >= this.#maximumAttempts || elapsed >= this.#maximumElapsedMs) {
      return { status: "exhausted" };
    }
    const attempt = this.#attempts + 1;
    const exponential = Math.min(
      this.#maximumDelayMs,
      this.#baseDelayMs * 2 ** this.#attempts,
    );
    const jitter = deterministicUnit(this.#jitterSeed, attempt) * 2 - 1;
    const jittered = Math.max(0, Math.round(exponential * (1 + jitter * this.#jitterRatio)));
    const delayMs = Math.min(jittered, Math.max(0, this.#maximumElapsedMs - elapsed));
    this.#attempts = attempt;
    this.#timer = this.#clock.schedule(() => {
      this.#timer = null;
      if (!this.#cancelled) callback(attempt);
    }, delayMs);
    return { status: "scheduled", attempt, delayMs };
  }

  markHealthy() {
    this.#clearTimer();
    this.#attempts = 0;
    this.#startedAt = null;
    this.#cancelled = false;
  }

  cancel() {
    this.#cancelled = true;
    this.#clearTimer();
  }

  resume() {
    this.#cancelled = false;
  }

  #clearTimer() {
    if (this.#timer !== null) this.#clock.cancel(this.#timer);
    this.#timer = null;
  }
}

function deterministicUnit(seed: number, attempt: number) {
  let value = (seed ^ Math.imul(attempt, 0x9e3779b1)) >>> 0;
  value ^= value >>> 16;
  value = Math.imul(value, 0x7feb352d) >>> 0;
  value ^= value >>> 15;
  value = Math.imul(value, 0x846ca68b) >>> 0;
  value ^= value >>> 16;
  return value / 0x1_0000_0000;
}
