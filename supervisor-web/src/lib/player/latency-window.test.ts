import { describe, expect, it } from "vitest";
import { LatencyWindow } from "./latency-window";

describe("LatencyWindow", () => {
  it("calcula percentiles nearest-rank y conserva el número de muestras", () => {
    const window = new LatencyWindow(10);
    for (const value of [10, 30, 20, 50, 40]) window.record(value);

    expect(window.snapshot()).toEqual({
      samples: 5,
      p50Ms: 30,
      p95Ms: 50,
      p99Ms: 50,
    });
  });

  it("mantiene una ventana circular acotada", () => {
    const window = new LatencyWindow(3);
    for (const value of [1, 2, 3, 100]) window.record(value);

    expect(window.snapshot()).toEqual({
      samples: 3,
      p50Ms: 3,
      p95Ms: 100,
      p99Ms: 100,
    });
  });

  it("ignora valores inválidos y puede reiniciarse", () => {
    const window = new LatencyWindow(4);
    window.record(Number.NaN);
    window.record(-1);
    window.record(8);
    window.clear();

    expect(window.snapshot()).toEqual({
      samples: 0,
      p50Ms: null,
      p95Ms: null,
      p99Ms: null,
    });
  });
});
