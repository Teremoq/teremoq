import { describe, expect, it } from "vitest";
import {
  INITIAL_WIFI_RECOVERY_SNAPSHOT,
  WIFI_RECOVERY_PROVENANCE,
  WIFI_RECOVERY_WINDOW_MS,
  WifiRecoveryObservation,
  type WifiRecoveryClock,
} from "./wifi-recovery";

class TestClock implements WifiRecoveryClock {
  time = 0;
  #nextId = 1;
  #timers = new Map<number, { at: number; callback: () => void }>();

  now() { return this.time; }
  schedule(callback: () => void, delayMs: number) {
    const id = this.#nextId++;
    this.#timers.set(id, { at: this.time + delayMs, callback });
    return id;
  }
  cancel(timer: number) { this.#timers.delete(timer); }
  advance(ms: number) {
    this.time += ms;
    for (const [id, timer] of [...this.#timers]) {
      if (timer.at <= this.time) {
        this.#timers.delete(id);
        timer.callback();
      }
    }
  }
  get timerCount() { return this.#timers.size; }
}

describe("observación manual de recuperación Wi-Fi", () => {
  it("sin armado no atribuye pérdidas ni Objects a Wi-Fi", () => {
    const clock = new TestClock();
    const observation = new WifiRecoveryObservation(() => undefined, clock);
    observation.observeSessionLoss(10);
    observation.observeRecoveredObject(20);
    expect(observation.snapshot).toEqual(INITIAL_WIFI_RECOVERY_SNAPSHOT);
  });

  it("armado sin pérdida mantiene la medición pendiente y acotada", () => {
    const clock = new TestClock();
    const observation = new WifiRecoveryObservation(() => undefined, clock);
    observation.arm();
    observation.observeRecoveredObject(20);
    expect(observation.snapshot).toMatchObject({
      status: "armed_waiting_loss",
      armed: true,
      lossObserved: false,
      recoveryMs: null,
      provenance: WIFI_RECOVERY_PROVENANCE,
    });
    clock.advance(WIFI_RECOVERY_WINDOW_MS);
    expect(observation.snapshot.status).toBe("expired");
    expect(clock.timerCount).toBe(0);
  });

  it("pérdida armada sin Object recuperado no produce valor", () => {
    const clock = new TestClock();
    const observation = new WifiRecoveryObservation(() => undefined, clock);
    observation.arm();
    observation.observeSessionLoss(100);
    expect(observation.snapshot).toMatchObject({
      status: "armed_waiting_recovery_object",
      lossObserved: true,
      recoveryObserved: false,
      recoveryMs: null,
    });
  });

  it("rechaza una recuperación observada fuera de la ventana aunque el timer se retrase", () => {
    const clock = new TestClock();
    const observation = new WifiRecoveryObservation(() => undefined, clock);
    observation.arm();
    observation.observeSessionLoss(1);
    observation.observeRecoveredObject(WIFI_RECOVERY_WINDOW_MS + 1);
    expect(observation.snapshot).toMatchObject({ status: "expired", recoveryMs: null });
    expect(clock.timerCount).toBe(0);
  });

  it("mide sólo pérdida armada seguida del primer Object recuperado", () => {
    const clock = new TestClock();
    const observation = new WifiRecoveryObservation(() => undefined, clock);
    observation.arm();
    observation.observeSessionLoss(1_000);
    observation.observeRecoveredObject(1_275.4);
    observation.observeRecoveredObject(2_000);
    expect(observation.snapshot).toMatchObject({
      status: "measured",
      armed: true,
      lossObserved: true,
      recoveryObserved: true,
      recoveryMs: 276,
    });
    expect(clock.timerCount).toBe(0);
  });

  it("rearma de forma limpia y el desmontaje cancela estado y timer", () => {
    const clock = new TestClock();
    const observation = new WifiRecoveryObservation(() => undefined, clock);
    observation.arm();
    observation.observeSessionLoss(5);
    observation.arm();
    expect(observation.snapshot).toMatchObject({
      status: "armed_waiting_loss",
      lossObserved: false,
      recoveryObserved: false,
      recoveryMs: null,
    });
    expect(clock.timerCount).toBe(1);
    observation.dispose();
    expect(observation.snapshot).toMatchObject({
      status: "cancelled",
      armed: false,
      lossObserved: false,
      recoveryObserved: false,
      recoveryMs: null,
      provenance: "not_available",
    });
    expect(clock.timerCount).toBe(0);
  });
});
