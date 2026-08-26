import { describe, expect, it } from "vitest";
import { FramePacer, type PacerClock, type TimestampedFrame } from "./frame-pacer";

type TestFrame = TimestampedFrame & { id: number; closed: boolean };

class TestClock implements PacerClock {
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

  stall(durationMs: number) {
    this.time += durationMs;
    while (true) {
      const next = [...this.#timers.entries()]
        .filter(([, timer]) => timer.at <= this.time)
        .sort((left, right) => left[1].at - right[1].at)[0];
      if (!next) return;
      this.#timers.delete(next[0]);
      next[1].callback();
    }
  }
}

function frame(id: number, timestamp: number): TestFrame {
  return {
    id,
    timestamp,
    closed: false,
    close() {
      this.closed = true;
    },
  };
}

describe("FramePacer", () => {
  it("spaces a decoded burst using media timestamps", () => {
    const clock = new TestClock();
    const rendered: Array<[number, number]> = [];
    const pacer = new FramePacer<TestFrame>(
      (current) => rendered.push([current.id, clock.now()]),
      () => undefined,
      clock,
    );

    pacer.push(frame(1, 0));
    pacer.push(frame(2, 33_333));
    pacer.push(frame(3, 66_666));
    clock.advance(350);

    expect(rendered.map(([id]) => id)).toEqual([1, 2, 3]);
    expect(rendered[0][1]).toBeCloseTo(250, 3);
    expect(rendered[1][1]).toBeCloseTo(283.333, 3);
    expect(rendered[2][1]).toBeCloseTo(316.666, 3);
  });

  it("limits catch-up to one frame per compositor interval", () => {
    const clock = new TestClock();
    const rendered: number[] = [];
    const dropped: number[] = [];
    const pacer = new FramePacer<TestFrame>(
      (current) => rendered.push(current.id),
      (current) => dropped.push(current.id),
      clock,
    );

    pacer.push(frame(1, 0));
    pacer.push(frame(2, 33_333));
    pacer.push(frame(3, 66_666));
    clock.stall(300);

    expect(rendered).toEqual([1]);
    clock.advance(16);
    expect(rendered).toEqual([1, 2]);
    clock.advance(16);
    expect(rendered).toEqual([1, 2, 3]);
    expect(dropped).toEqual([]);
  });

  it("bounds decoded-frame memory and closes discarded frames", () => {
    const clock = new TestClock();
    const dropped: TestFrame[] = [];
    const pacer = new FramePacer<TestFrame>(
      () => undefined,
      (current) => dropped.push(current),
      clock,
      { maxFrames: 2 },
    );

    pacer.push(frame(1, 0));
    pacer.push(frame(2, 33_333));
    pacer.push(frame(3, 66_666));

    expect(dropped.map((current) => current.id)).toEqual([1]);
    expect(dropped[0].closed).toBe(true);
  });

  it("recovers from an underflow without applying the full startup buffer", () => {
    const clock = new TestClock();
    const rendered: Array<[number, number]> = [];
    const pacer = new FramePacer<TestFrame>(
      (current) => rendered.push([current.id, clock.now()]),
      () => undefined,
      clock,
    );
    pacer.push(frame(1, 0));
    clock.advance(250);
    clock.advance(200);

    pacer.push(frame(2, 33_333));
    clock.advance(49);
    expect(rendered).toEqual([[1, 250]]);
    clock.advance(1);

    expect(rendered).toEqual([
      [1, 250],
      [2, 500],
    ]);
  });

  it("allows an explicit bounded underflow recovery margin", () => {
    const clock = new TestClock();
    const rendered: Array<[number, number]> = [];
    const pacer = new FramePacer<TestFrame>(
      (current) => rendered.push([current.id, clock.now()]),
      () => undefined,
      clock,
      { targetLatencyMs: 250, recoveryLatencyMs: 20 },
    );

    pacer.push(frame(1, 0));
    clock.advance(450);
    pacer.push(frame(2, 33_333));
    clock.advance(20);

    expect(rendered).toEqual([
      [1, 250],
      [2, 470],
    ]);
  });

  it("closes every queued frame when cleared", () => {
    const clock = new TestClock();
    const first = frame(1, 0);
    const second = frame(2, 33_333);
    const pacer = new FramePacer<TestFrame>(() => undefined, () => undefined, clock);
    pacer.push(first);
    pacer.push(second);

    pacer.clear();
    clock.advance(200);

    expect(first.closed).toBe(true);
    expect(second.closed).toBe(true);
  });
});
