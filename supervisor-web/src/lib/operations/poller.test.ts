import { describe, expect, it } from "vitest";
import { SingleFlightPoller, type PollClock, type PollEvent } from "./poller";

class TestClock implements PollClock {
  time = 0;
  #id = 1;
  #timers = new Map<number, { at: number; callback: () => void }>();
  now() { return this.time; }
  schedule(callback: () => void, delayMs: number) { const id = this.#id++; this.#timers.set(id, { at: this.time + delayMs, callback }); return id; }
  cancel(id: number) { this.#timers.delete(id); }
  advance(ms: number) {
    const target = this.time + ms;
    while (true) {
      const next = [...this.#timers.entries()].filter(([, timer]) => timer.at <= target).sort((a, b) => a[1].at - b[1].at)[0];
      if (!next) break;
      this.time = next[1].at;
      this.#timers.delete(next[0]);
      next[1].callback();
    }
    this.time = target;
  }
  get count() { return this.#timers.size; }
}

function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (cause: unknown) => void;
  const promise = new Promise<T>((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}

async function flush() { await Promise.resolve(); await Promise.resolve(); }

describe("SingleFlightPoller", () => {
  it("no solapa peticiones y programa una sola sucesora", async () => {
    const clock = new TestClock();
    const first = deferred<number>();
    const second = deferred<number>();
    let calls = 0;
    const poller = new SingleFlightPoller(
      () => (++calls === 1 ? first.promise : second.promise),
      () => undefined,
      clock,
      { intervalMs: 100, timeoutMs: 1_000, maximumIntervalMs: 800 },
    );
    poller.start();
    clock.advance(900);
    expect(calls).toBe(1);
    first.resolve(1);
    await flush();
    clock.advance(99);
    expect(calls).toBe(1);
    clock.advance(1);
    expect(calls).toBe(2);
    poller.stop();
    second.reject(new Error("stopped"));
    await flush();
    expect(clock.count).toBe(0);
  });

  it("aplica backoff acotado y se recupera al intervalo base", async () => {
    const clock = new TestClock();
    const events: PollEvent<number>[] = [];
    let calls = 0;
    const poller = new SingleFlightPoller(
      async () => { calls += 1; if (calls < 3) throw new Error("offline"); return 7; },
      (event) => events.push(event),
      clock,
      { intervalMs: 100, timeoutMs: 1_000, maximumIntervalMs: 250 },
    );
    poller.start();
    await flush();
    clock.advance(199);
    expect(calls).toBe(1);
    clock.advance(1);
    await flush();
    clock.advance(249);
    expect(calls).toBe(2);
    clock.advance(1);
    await flush();
    expect(calls).toBe(3);
    expect(events.map(({ type }) => type)).toEqual(["failure", "failure", "success"]);
    clock.advance(100);
    expect(calls).toBe(4);
    poller.stop();
  });

  it("aborta por timeout y teardown sin callbacks tardíos", async () => {
    const clock = new TestClock();
    const events: PollEvent<number>[] = [];
    const fetcher = (signal: AbortSignal) => new Promise<number>((_resolve, reject) => {
      signal.addEventListener("abort", () => reject(new DOMException("aborted", "AbortError")), { once: true });
    });
    const poller = new SingleFlightPoller(fetcher, (event) => events.push(event), clock, { intervalMs: 100, timeoutMs: 50 });
    poller.start();
    clock.advance(50);
    await flush();
    expect(events).toHaveLength(1);
    expect(events[0]).toMatchObject({ type: "failure", reason: "source-unreachable" });
    poller.stop();
    clock.advance(10_000);
    await flush();
    expect(events).toHaveLength(1);
    expect(clock.count).toBe(0);
  });

  it("distingue rechazo de dato y pérdida de fuente", async () => {
    const clock = new TestClock();
    const events: PollEvent<number>[] = [];
    const rejected = Object.assign(new Error("bad"), { name: "OperationsDataError" });
    const poller = new SingleFlightPoller(async () => { throw rejected; }, (event) => events.push(event), clock);
    poller.start();
    await flush();
    expect(events[0]).toMatchObject({ type: "failure", reason: "data-rejected" });
    poller.stop();
  });
});
