export type PollClock = {
  now(): number;
  schedule(callback: () => void, delayMs: number): number;
  cancel(timer: number): void;
};

export type PollEvent<T> =
  | { type: "success"; value: T; at: number }
  | { type: "failure"; reason: "source-unreachable" | "data-rejected" | "not-configured"; at: number };

type PollerOptions = {
  intervalMs?: number;
  timeoutMs?: number;
  maximumIntervalMs?: number;
};

const browserClock: PollClock = {
  now: () => performance.now(),
  schedule: (callback, delayMs) => window.setTimeout(callback, delayMs),
  cancel: (timer) => window.clearTimeout(timer),
};

/** One generation, one in-flight request and one bounded successor timer. */
export class SingleFlightPoller<T> {
  readonly #fetcher: (signal: AbortSignal) => Promise<T>;
  readonly #listener: (event: PollEvent<T>) => void;
  readonly #clock: PollClock;
  readonly #intervalMs: number;
  readonly #timeoutMs: number;
  readonly #maximumIntervalMs: number;
  #generation = 0;
  #failures = 0;
  #timer: number | null = null;
  #timeoutTimer: number | null = null;
  #controller: AbortController | null = null;

  constructor(
    fetcher: (signal: AbortSignal) => Promise<T>,
    listener: (event: PollEvent<T>) => void,
    clock: PollClock = browserClock,
    options: PollerOptions = {},
  ) {
    this.#fetcher = fetcher;
    this.#listener = listener;
    this.#clock = clock;
    this.#intervalMs = options.intervalMs ?? 1_000;
    this.#timeoutMs = options.timeoutMs ?? 2_500;
    this.#maximumIntervalMs = options.maximumIntervalMs ?? 15_000;
  }

  start() {
    this.stop();
    const generation = ++this.#generation;
    void this.#poll(generation);
  }

  stop() {
    this.#generation += 1;
    if (this.#timer !== null) this.#clock.cancel(this.#timer);
    if (this.#timeoutTimer !== null) this.#clock.cancel(this.#timeoutTimer);
    this.#timer = null;
    this.#timeoutTimer = null;
    this.#controller?.abort();
    this.#controller = null;
    this.#failures = 0;
  }

  async #poll(generation: number) {
    if (generation !== this.#generation || this.#controller !== null) return;
    const controller = new AbortController();
    this.#controller = controller;
    let timedOut = false;
    this.#timeoutTimer = this.#clock.schedule(() => {
      timedOut = true;
      controller.abort();
    }, this.#timeoutMs);
    try {
      const value = await this.#fetcher(controller.signal);
      if (generation !== this.#generation) return;
      this.#failures = 0;
      this.#listener({ type: "success", value, at: this.#clock.now() });
    } catch (cause: unknown) {
      if (generation !== this.#generation) return;
      this.#failures += 1;
      this.#listener({
        type: "failure",
        reason: failureReason(cause),
        at: this.#clock.now(),
      });
      void timedOut;
    } finally {
      if (this.#timeoutTimer !== null) this.#clock.cancel(this.#timeoutTimer);
      this.#timeoutTimer = null;
      if (this.#controller === controller) this.#controller = null;
      if (generation === this.#generation) {
        const delay = Math.min(
          this.#maximumIntervalMs,
          this.#intervalMs * 2 ** Math.min(this.#failures, 8),
        );
        this.#timer = this.#clock.schedule(() => {
          this.#timer = null;
          void this.#poll(generation);
        }, delay);
      }
    }
  }
}

function failureReason(cause: unknown): "source-unreachable" | "data-rejected" | "not-configured" {
  if (cause instanceof Error && cause.message === "not-configured") return "not-configured";
  if (
    typeof cause === "object" &&
    cause !== null &&
    "name" in cause &&
    cause.name === "OperationsDataError"
  ) return "data-rejected";
  return "source-unreachable";
}
