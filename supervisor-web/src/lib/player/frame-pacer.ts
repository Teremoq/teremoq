const DEFAULT_TARGET_LATENCY_MS = 250;
const DEFAULT_RECOVERY_LATENCY_MS = 50;
const DEFAULT_LATE_TOLERANCE_MS = 50;
const DEFAULT_MAX_FRAMES = 32;
const MINIMUM_PRESENTATION_SEPARATION_MS = 16;
const COMPOSITOR_EARLY_TOLERANCE_MS = 17;

export type TimestampedFrame = {
  timestamp: number;
  close(): void;
};

export type PacerClock = {
  now(): number;
  schedule(callback: () => void, delayMs: number): number;
  cancel(timer: number): void;
};

type FramePacerOptions = {
  targetLatencyMs?: number;
  recoveryLatencyMs?: number;
  lateToleranceMs?: number;
  maxFrames?: number;
};

const browserClock: PacerClock = {
  now: () => performance.now(),
  // Canvas presentation follows the compositor clock. setTimeout is subject
  // to browser timer throttling and turns a 30 fps stream into visible bursts.
  schedule: (callback) => window.requestAnimationFrame(() => callback()),
  cancel: (timer) => window.cancelAnimationFrame(timer),
};

/**
 * Converts bursty decoder output into media-timestamp paced presentation.
 * The queue is deliberately small: when the browser falls behind we discard
 * already decoded pictures instead of increasing glass-to-glass latency.
 */
export class FramePacer<T extends TimestampedFrame> {
  readonly #render: (frame: T) => void;
  readonly #drop: (frame: T) => void;
  readonly #clock: PacerClock;
  readonly #targetLatencyMs: number;
  readonly #recoveryLatencyMs: number;
  readonly #lateToleranceMs: number;
  readonly #maxFrames: number;
  readonly #queue: T[] = [];
  #anchorMediaUs: number | null = null;
  #anchorWallMs = 0;
  #lastTimestampUs = -1;
  #lastPresentationMs = Number.NEGATIVE_INFINITY;
  #timer: number | null = null;

  constructor(
    render: (frame: T) => void,
    drop: (frame: T) => void,
    clock: PacerClock = browserClock,
    options: FramePacerOptions = {},
  ) {
    this.#render = render;
    this.#drop = drop;
    this.#clock = clock;
    this.#targetLatencyMs = options.targetLatencyMs ?? DEFAULT_TARGET_LATENCY_MS;
    this.#recoveryLatencyMs = options.recoveryLatencyMs ?? DEFAULT_RECOVERY_LATENCY_MS;
    this.#lateToleranceMs = options.lateToleranceMs ?? DEFAULT_LATE_TOLERANCE_MS;
    this.#maxFrames = options.maxFrames ?? DEFAULT_MAX_FRAMES;
  }

  push(frame: T) {
    const previous = this.#queue.at(-1)?.timestamp ?? this.#lastTimestampUs;
    if (frame.timestamp <= previous) {
      this.#discard(frame);
      return;
    }

    const now = this.#clock.now();
    if (this.#anchorMediaUs === null) {
      this.#anchorMediaUs = frame.timestamp;
      this.#anchorWallMs = now + this.#targetLatencyMs;
    } else if (this.#queue.length === 0 && this.#target(frame) < now - this.#lateToleranceMs) {
      // Do not replay a late burst quickly. Start a new wall-clock epoch with
      // a short recovery margin: applying the full startup buffer here would
      // turn a transient underflow into a visible half-second freeze.
      this.#anchorMediaUs = frame.timestamp;
      this.#anchorWallMs = now + this.#recoveryLatencyMs;
    }

    this.#queue.push(frame);
    while (this.#queue.length > this.#maxFrames) {
      const dropped = this.#queue.shift();
      if (dropped) this.#discard(dropped);
    }
    this.#scheduleNext();
  }

  clear() {
    if (this.#timer !== null) this.#clock.cancel(this.#timer);
    this.#timer = null;
    for (const frame of this.#queue.splice(0)) this.#discard(frame);
    this.#anchorMediaUs = null;
    this.#anchorWallMs = 0;
    this.#lastTimestampUs = -1;
    this.#lastPresentationMs = Number.NEGATIVE_INFINITY;
  }

  #scheduleNext() {
    if (this.#timer !== null || this.#queue.length === 0) return;
    const now = this.#clock.now();
    const delayMs = Math.max(
      0,
      this.#target(this.#queue[0]) - now,
      this.#lastPresentationMs + MINIMUM_PRESENTATION_SEPARATION_MS - now,
    );
    this.#timer = this.#clock.schedule(() => this.#presentDueFrame(), delayMs);
  }

  #presentDueFrame() {
    this.#timer = null;
    const now = this.#clock.now();

    const frame = this.#queue[0];
    if (!frame) return;
    const remainingMs = this.#target(frame) - now;
    // A compositor tick can be 16.7 ms (60 Hz) or 33.3 ms in constrained
    // headless/embedded displays. Accepting the next half-frame prevents a
    // 30 Hz compositor from presenting a 30 fps source on every second tick.
    if (remainingMs > COMPOSITOR_EARLY_TOLERANCE_MS) {
      this.#scheduleNext();
      return;
    }

    this.#queue.shift();
    this.#lastTimestampUs = frame.timestamp;
    this.#lastPresentationMs = now;
    this.#render(frame);
    this.#scheduleNext();
  }

  #target(frame: T) {
    if (this.#anchorMediaUs === null) return this.#clock.now();
    return this.#anchorWallMs + (frame.timestamp - this.#anchorMediaUs) / 1_000;
  }

  #discard(frame: T) {
    this.#drop(frame);
    frame.close();
  }
}
