import type { ReconnectClock } from "./reconnect";

type ActivityWatchdogCallbacks = {
  onVideoStale(): void;
  onPeerSilent(): void;
};

type ActivityWatchdogOptions = {
  staleAfterMs?: number;
  silentAfterMs?: number;
};

const browserClock: ReconnectClock = {
  now: () => performance.now(),
  schedule: (callback, delayMs) => window.setTimeout(callback, delayMs),
  cancel: (timer) => window.clearTimeout(timer),
};

export class ActivityWatchdog {
  readonly #clock: ReconnectClock;
  readonly #callbacks: ActivityWatchdogCallbacks;
  readonly #staleAfterMs: number;
  readonly #silentAfterMs: number;
  #staleTimer: number | null = null;
  #silenceTimer: number | null = null;

  constructor(
    callbacks: ActivityWatchdogCallbacks,
    clock: ReconnectClock = browserClock,
    options: ActivityWatchdogOptions = {},
  ) {
    this.#callbacks = callbacks;
    this.#clock = clock;
    this.#staleAfterMs = options.staleAfterMs ?? 3_000;
    this.#silentAfterMs = options.silentAfterMs ?? 8_000;
  }

  markSessionActivity() {
    if (this.#silenceTimer !== null) this.#clock.cancel(this.#silenceTimer);
    this.#silenceTimer = this.#clock.schedule(() => {
      this.#silenceTimer = null;
      this.#callbacks.onPeerSilent();
    }, this.#silentAfterMs);
  }

  markVideoActivity() {
    this.markSessionActivity();
    if (this.#staleTimer !== null) this.#clock.cancel(this.#staleTimer);
    this.#staleTimer = this.#clock.schedule(() => {
      this.#staleTimer = null;
      this.#callbacks.onVideoStale();
    }, this.#staleAfterMs);
  }

  cancel() {
    if (this.#staleTimer !== null) this.#clock.cancel(this.#staleTimer);
    if (this.#silenceTimer !== null) this.#clock.cancel(this.#silenceTimer);
    this.#staleTimer = null;
    this.#silenceTimer = null;
  }
}
