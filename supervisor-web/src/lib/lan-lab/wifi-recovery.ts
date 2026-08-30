export const WIFI_RECOVERY_WINDOW_MS = 180_000;
export const WIFI_RECOVERY_PROVENANCE =
  "operator-armed-browser-monotonic-session-loss-to-first-recovered-object" as const;

export type WifiRecoveryStatus =
  | "not_measured"
  | "armed_waiting_loss"
  | "armed_waiting_recovery_object"
  | "measured"
  | "cancelled"
  | "expired";

export type WifiRecoverySnapshot = Readonly<{
  status: WifiRecoveryStatus;
  armed: boolean;
  lossObserved: boolean;
  recoveryObserved: boolean;
  recoveryMs: number | null;
  provenance: typeof WIFI_RECOVERY_PROVENANCE | "not_available";
}>;

export interface WifiRecoveryClock {
  now(): number;
  schedule(callback: () => void, delayMs: number): number;
  cancel(timer: number): void;
}

export const INITIAL_WIFI_RECOVERY_SNAPSHOT: WifiRecoverySnapshot = Object.freeze({
  status: "not_measured",
  armed: false,
  lossObserved: false,
  recoveryObserved: false,
  recoveryMs: null,
  provenance: "not_available",
});

export class WifiRecoveryObservation {
  readonly #onSnapshot: (snapshot: WifiRecoverySnapshot) => void;
  readonly #clock: WifiRecoveryClock;
  #snapshot = INITIAL_WIFI_RECOVERY_SNAPSHOT;
  #lossObservedAtMs: number | null = null;
  #expiresAtMs: number | null = null;
  #timer: number | null = null;

  constructor(
    onSnapshot: (snapshot: WifiRecoverySnapshot) => void,
    clock: WifiRecoveryClock = browserClock(),
  ) {
    this.#onSnapshot = onSnapshot;
    this.#clock = clock;
  }

  get snapshot() {
    return this.#snapshot;
  }

  arm() {
    this.#clearTimer();
    this.#lossObservedAtMs = null;
    this.#expiresAtMs = this.#clock.now() + WIFI_RECOVERY_WINDOW_MS;
    this.#update({
      status: "armed_waiting_loss",
      armed: true,
      lossObserved: false,
      recoveryObserved: false,
      recoveryMs: null,
      provenance: WIFI_RECOVERY_PROVENANCE,
    });
    this.#timer = this.#clock.schedule(() => this.#expire(), WIFI_RECOVERY_WINDOW_MS);
  }

  observeSessionLoss(observedAtMs = this.#clock.now()) {
    if (this.#snapshot.status !== "armed_waiting_loss" || !finiteTimestamp(observedAtMs)) return;
    if (this.#expiresAtMs === null || observedAtMs > this.#expiresAtMs) {
      this.#expire();
      return;
    }
    this.#lossObservedAtMs = observedAtMs;
    this.#update({
      ...this.#snapshot,
      status: "armed_waiting_recovery_object",
      lossObserved: true,
    });
  }

  observeRecoveredObject(observedAtMs = this.#clock.now()) {
    if (this.#snapshot.status !== "armed_waiting_recovery_object" ||
        this.#lossObservedAtMs === null || !finiteTimestamp(observedAtMs) ||
        observedAtMs < this.#lossObservedAtMs) return;
    if (this.#expiresAtMs === null || observedAtMs > this.#expiresAtMs) {
      this.#expire();
      return;
    }
    const recoveryMs = observedAtMs - this.#lossObservedAtMs;
    if (recoveryMs <= 0) return;
    this.#clearTimer();
    this.#update({
      ...this.#snapshot,
      status: "measured",
      recoveryObserved: true,
      recoveryMs: Math.ceil(recoveryMs),
    });
  }

  cancel() {
    if (this.#snapshot.status !== "armed_waiting_loss" &&
        this.#snapshot.status !== "armed_waiting_recovery_object") return;
    this.#clearTimer();
    this.#lossObservedAtMs = null;
    this.#expiresAtMs = null;
    this.#update({ ...this.#snapshot, status: "cancelled" });
  }

  reset() {
    this.#clearTimer();
    this.#lossObservedAtMs = null;
    this.#expiresAtMs = null;
    this.#update(INITIAL_WIFI_RECOVERY_SNAPSHOT);
  }

  dispose() {
    this.#clearTimer();
    this.#lossObservedAtMs = null;
    this.#expiresAtMs = null;
    if (this.#snapshot !== INITIAL_WIFI_RECOVERY_SNAPSHOT) {
      this.#update({
        status: "cancelled",
        armed: false,
        lossObserved: false,
        recoveryObserved: false,
        recoveryMs: null,
        provenance: "not_available",
      });
    }
  }

  #expire() {
    this.#clearTimer();
    this.#lossObservedAtMs = null;
    this.#expiresAtMs = null;
    if (this.#snapshot.status === "armed_waiting_loss" ||
        this.#snapshot.status === "armed_waiting_recovery_object") {
      this.#update({ ...this.#snapshot, status: "expired" });
    }
  }

  #clearTimer() {
    if (this.#timer === null) return;
    this.#clock.cancel(this.#timer);
    this.#timer = null;
  }

  #update(snapshot: WifiRecoverySnapshot) {
    this.#snapshot = Object.freeze(snapshot);
    this.#onSnapshot(this.#snapshot);
  }
}

function browserClock(): WifiRecoveryClock {
  return {
    now: () => performance.now(),
    schedule: (callback, delayMs) => window.setTimeout(callback, delayMs),
    cancel: (timer) => window.clearTimeout(timer),
  };
}

function finiteTimestamp(value: number) {
  return Number.isFinite(value) && value >= 0;
}
