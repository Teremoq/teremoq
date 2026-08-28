import { describe, expect, it } from "vitest";
import { ActivityWatchdog } from "./activity-watchdog";
import { BoundedReconnect, type ReconnectClock } from "./reconnect";

class TestClock implements ReconnectClock {
  time = 0;
  #nextId = 1;
  #timers = new Map<number, { at: number; callback: () => void }>();

  now() {
    return this.time;
  }

  schedule(callback: () => void, delayMs: number) {
    const id = this.#nextId++;
    this.#timers.set(id, { at: this.time + delayMs, callback });
    return id;
  }

  cancel(timer: number) {
    this.#timers.delete(timer);
  }

  advance(durationMs: number) {
    const target = this.time + durationMs;
    while (true) {
      const next = [...this.#timers.entries()]
        .filter(([, timer]) => timer.at <= target)
        .sort((left, right) => left[1].at - right[1].at)[0];
      if (!next) break;
      this.time = next[1].at;
      this.#timers.delete(next[0]);
      next[1].callback();
    }
    this.time = target;
  }

  runNext() {
    const next = [...this.#timers.values()].sort((left, right) => left.at - right.at)[0];
    if (!next) return false;
    this.advance(next.at - this.time);
    return true;
  }

  get timerCount() {
    return this.#timers.size;
  }
}

describe("BoundedReconnect", () => {
  it("agota una tormenta de reconexiones sin dejar timers", () => {
    const clock = new TestClock();
    const reconnect = new BoundedReconnect(clock, {
      maximumAttempts: 6,
      maximumElapsedMs: 30_000,
      jitterSeed: 7,
    });
    let attempts = 0;
    let exhausted = false;
    const retry = () => {
      attempts += 1;
      exhausted = reconnect.schedule(retry).status === "exhausted";
    };

    expect(reconnect.schedule(retry).status).toBe("scheduled");
    while (clock.runNext()) {
      // The callback schedules at most one successor.
    }

    expect(attempts).toBe(6);
    expect(exhausted).toBe(true);
    expect(clock.time).toBeLessThanOrEqual(30_000);
    expect(clock.timerCount).toBe(0);
  });

  it("produce jitter determinista y acotado", () => {
    const left = new BoundedReconnect(new TestClock(), { jitterSeed: 42 });
    const right = new BoundedReconnect(new TestClock(), { jitterSeed: 42 });
    const leftDecision = left.schedule(() => undefined);
    const rightDecision = right.schedule(() => undefined);

    expect(leftDecision).toEqual(rightDecision);
    expect(leftDecision).toMatchObject({ status: "scheduled", attempt: 1 });
    if (leftDecision.status === "scheduled") {
      expect(leftDecision.delayMs).toBeGreaterThanOrEqual(200);
      expect(leftDecision.delayMs).toBeLessThanOrEqual(300);
    }
  });

  it("cancela inmediatamente el reintento pendiente", () => {
    const clock = new TestClock();
    const reconnect = new BoundedReconnect(clock);
    let called = false;
    reconnect.schedule(() => { called = true; });

    reconnect.cancel();
    clock.advance(60_000);

    expect(called).toBe(false);
    expect(clock.timerCount).toBe(0);
  });
});

describe("ActivityWatchdog", () => {
  it("marca vídeo stale y después detecta un peer silencioso", () => {
    const clock = new TestClock();
    const events: string[] = [];
    const watchdog = new ActivityWatchdog(
      {
        onVideoStale: () => events.push("stale"),
        onPeerSilent: () => events.push("silent"),
      },
      clock,
    );

    watchdog.markVideoActivity();
    clock.advance(3_000);
    expect(events).toEqual(["stale"]);
    clock.advance(5_000);
    expect(events).toEqual(["stale", "silent"]);
  });

  it("mantiene telemetría continua aislada aunque el vídeo quede stale", () => {
    const clock = new TestClock();
    const events: string[] = [];
    const watchdog = new ActivityWatchdog(
      {
        onVideoStale: () => events.push("stale"),
        onPeerSilent: () => events.push("silent"),
      },
      clock,
    );
    watchdog.markVideoActivity();

    for (let second = 1; second <= 10; second += 1) {
      clock.advance(1_000);
      watchdog.markSessionActivity();
    }

    expect(events).toEqual(["stale"]);
    expect(clock.timerCount).toBe(1);
    watchdog.cancel();
    expect(clock.timerCount).toBe(0);
  });
});
