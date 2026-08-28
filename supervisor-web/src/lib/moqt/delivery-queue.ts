import type { MoqObject } from "./subgroup";

export type DeliveryClass = "control" | "video" | "critical";
export type DeliveryResult =
  | "queued"
  | "video-dropped"
  | "video-resynced"
  | "overflow"
  | "closed";

const DEFAULT_MAX_OBJECTS = 32;
const DEFAULT_MAX_BYTES = 4 * 1024 * 1024;

/** Serial, bounded delivery for one Track alias; queues never span aliases. */
export class TrackDeliveryQueue {
  readonly #handler: (object: MoqObject) => void | Promise<void>;
  readonly #deliveryClass: DeliveryClass;
  readonly #onError: (cause: unknown) => void;
  readonly #maximumObjects: number;
  readonly #maximumBytes: number;
  readonly #queue: MoqObject[] = [];
  #queuedBytes = 0;
  #inFlightBytes = 0;
  #running = false;
  #closed = false;

  constructor(
    handler: (object: MoqObject) => void | Promise<void>,
    deliveryClass: DeliveryClass,
    onError: (cause: unknown) => void,
    limits: { maximumObjects?: number; maximumBytes?: number } = {},
  ) {
    this.#handler = handler;
    this.#deliveryClass = deliveryClass;
    this.#onError = onError;
    this.#maximumObjects = limits.maximumObjects ?? DEFAULT_MAX_OBJECTS;
    this.#maximumBytes = limits.maximumBytes ?? DEFAULT_MAX_BYTES;
  }

  enqueue(object: MoqObject): DeliveryResult {
    if (this.#closed) return "closed";
    const admission = this.#admit(object);
    if (!admission.fits) {
      if (this.#deliveryClass !== "video" || isVideoKey(object)) return "overflow";
      return "video-dropped";
    }
    this.#queue.push(object);
    this.#queuedBytes += object.payload.byteLength;
    this.#drain();
    return admission.resynced ? "video-resynced" : "queued";
  }

  close() {
    if (this.#closed) return;
    this.#closed = true;
    this.#queue.length = 0;
    this.#queuedBytes = 0;
  }

  get pendingObjects() {
    return this.#queue.length + (this.#running ? 1 : 0);
  }

  #admit(object: MoqObject) {
    if (
      this.#queue.length + (this.#running ? 1 : 0) < this.#maximumObjects &&
      this.#queuedBytes + this.#inFlightBytes + object.payload.byteLength <= this.#maximumBytes
    ) {
      return { fits: true, resynced: false };
    }
    if (this.#deliveryClass !== "video" || !isVideoKey(object)) {
      return { fits: false, resynced: false };
    }
    // A fresh random access point supersedes queued deltas. Never discard the
    // keyframe itself merely because decode/render fell behind.
    for (let index = this.#queue.length - 1; index >= 0; index -= 1) {
      if (isVideoKey(this.#queue[index])) continue;
      this.#queuedBytes -= this.#queue[index].payload.byteLength;
      this.#queue.splice(index, 1);
    }
    return {
      fits:
      this.#queue.length + (this.#running ? 1 : 0) < this.#maximumObjects &&
      this.#queuedBytes + this.#inFlightBytes + object.payload.byteLength <= this.#maximumBytes,
      resynced: true,
    };
  }

  #drain() {
    if (this.#running || this.#closed) return;
    const object = this.#queue.shift();
    if (!object) return;
    this.#queuedBytes -= object.payload.byteLength;
    this.#inFlightBytes = object.payload.byteLength;
    this.#running = true;
    void Promise.resolve()
      .then(() => this.#handler(object))
      .catch(this.#onError)
      .finally(() => {
        this.#inFlightBytes = 0;
        this.#running = false;
        this.#drain();
      });
  }
}

function isVideoKey(object: MoqObject) {
  return object.subgroupId + object.streamObjectIndex === 0;
}
