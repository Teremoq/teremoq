export type LatencyPercentiles = {
  samples: number;
  p50Ms: number | null;
  p95Ms: number | null;
  p99Ms: number | null;
};

export class LatencyWindow {
  readonly #capacity: number;
  readonly #values: number[] = [];
  #next = 0;

  constructor(capacity: number) {
    if (!Number.isSafeInteger(capacity) || capacity < 1) {
      throw new RangeError("la capacidad de latencia debe ser un entero positivo");
    }
    this.#capacity = capacity;
  }

  record(valueMs: number) {
    if (!Number.isFinite(valueMs) || valueMs < 0) return;
    if (this.#values.length < this.#capacity) {
      this.#values.push(valueMs);
    } else {
      this.#values[this.#next] = valueMs;
    }
    this.#next = (this.#next + 1) % this.#capacity;
  }

  clear() {
    this.#values.length = 0;
    this.#next = 0;
  }

  snapshot(): LatencyPercentiles {
    if (this.#values.length === 0) {
      return { samples: 0, p50Ms: null, p95Ms: null, p99Ms: null };
    }
    const sorted = [...this.#values].sort((left, right) => left - right);
    return {
      samples: sorted.length,
      p50Ms: percentile(sorted, 0.5),
      p95Ms: percentile(sorted, 0.95),
      p99Ms: percentile(sorted, 0.99),
    };
  }
}

function percentile(sorted: readonly number[], quantile: number) {
  const index = Math.max(0, Math.ceil(quantile * sorted.length) - 1);
  return sorted[Math.min(index, sorted.length - 1)] ?? null;
}
