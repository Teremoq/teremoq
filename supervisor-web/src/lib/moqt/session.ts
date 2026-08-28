import { ControlReader, encodeClientSetup, encodeSubscribe } from "./control";
import { MoqProtocolError } from "./binary";
import { MoqObject, readSubgroupStream } from "./subgroup";
import { TrackDeliveryQueue, type DeliveryClass } from "./delivery-queue";

// One ordered Subgroup remains open per active Track/Group. Eight readers cover
// the four logical Tracks plus bounded Group transitions without allowing a
// peer to allocate unbounded stream parser state.
const MAX_ACTIVE_STREAMS = 8;
const MAX_EARLY_ALIASES = 8;
const MAX_EARLY_OBJECTS = 96;
const MAX_EARLY_BYTES = 8 * 1024 * 1024;
const DROP_EVENT_INTERVAL_MS = 500;

export type ObjectHandler = (object: MoqObject) => void | Promise<void>;

export class WebTransportTrustError extends Error {
  constructor() {
    super("no se pudo autenticar el transporte WebTransport");
    this.name = "WebTransportTrustError";
  }
}

export type SessionEvent =
  | { type: "connected" }
  | { type: "subscribed"; track: string; alias: number }
  | {
      type: "stream-dropped";
      reason: "invalid-stream" | "unconfirmed-alias" | "video-pressure";
    }
  | { type: "error"; error: Error };

type PendingSubscription = {
  track: string;
  handler: ObjectHandler;
  deliveryClass: DeliveryClass;
  resolve: (alias: number) => void;
  reject: (error: Error) => void;
};

export class MoqSession {
  readonly #transport: WebTransport;
  readonly #control: WebTransportBidirectionalStream;
  readonly #controlReader: ControlReader;
  readonly #controlWriter: WritableStreamDefaultWriter<Uint8Array>;
  readonly #incomingReader: ReadableStreamDefaultReader<ReadableStream<Uint8Array>>;
  readonly #onEvent: (event: SessionEvent) => void;
  readonly #abortController = new AbortController();
  readonly #pending = new Map<number, PendingSubscription>();
  readonly #handlers = new Map<number, TrackDeliveryQueue>();
  readonly #earlyObjects = new Map<number, MoqObject[]>();
  readonly #activeStreams = new Set<Promise<void>>();
  #nextRequestId = 0;
  #earlyObjectCount = 0;
  #earlyByteCount = 0;
  #lastDropEventAt = Number.NEGATIVE_INFINITY;
  #closed = false;
  #closePromise: Promise<void> | null = null;
  #removeExternalAbort: (() => void) | null = null;
  #controlLoop: Promise<void> | null = null;
  #incomingLoop: Promise<void> | null = null;

  private constructor(
    transport: WebTransport,
    control: WebTransportBidirectionalStream,
    onEvent: (event: SessionEvent) => void,
  ) {
    this.#transport = transport;
    this.#control = control;
    this.#controlReader = new ControlReader(
      control.readable as ReadableStream<Uint8Array>,
      this.#abortController.signal,
    );
    this.#controlWriter = (
      control.writable as WritableStream<Uint8Array>
    ).getWriter();
    this.#incomingReader = (
      transport.incomingUnidirectionalStreams as ReadableStream<ReadableStream<Uint8Array>>
    ).getReader();
    this.#onEvent = onEvent;
    this.#abortController.signal.addEventListener(
      "abort",
      () => void this.#incomingReader.cancel("sesión cancelada").catch(() => undefined),
      { once: true },
    );
  }

  static async connect(
    url: string,
    certificateSha256: Uint8Array,
    onEvent: (event: SessionEvent) => void,
    signal?: AbortSignal,
  ) {
    if (certificateSha256.byteLength !== 32) {
      throw new MoqProtocolError("el fingerprint SHA-256 debe contener 32 bytes");
    }
    const certificateBuffer = new ArrayBuffer(32);
    new Uint8Array(certificateBuffer).set(certificateSha256);
    if (signal?.aborted) throw abortError();
    const transport = new WebTransport(url, {
      congestionControl: "low-latency",
      serverCertificateHashes: [
        { algorithm: "sha-256", value: certificateBuffer },
      ],
    });
    const abortPendingTransport = () => transport.close({ closeCode: 0, reason: "cancelado" });
    signal?.addEventListener("abort", abortPendingTransport, { once: true });
    let session: MoqSession | null = null;
    let transportReady = false;
    try {
      await transport.ready;
      transportReady = true;
      if (signal?.aborted) throw abortError();
      const control = await transport.createBidirectionalStream();
      session = new MoqSession(transport, control, onEvent);
      const connectedSession = session;
      signal?.removeEventListener("abort", abortPendingTransport);
      connectedSession.#linkExternalAbort(signal);
      await connectedSession.#controlWriter.write(encodeClientSetup());
      const setup = await connectedSession.#controlReader.next();
      if (setup.type !== "server-setup") {
        void connectedSession.close(0x03, "protocolo incompatible");
        throw new MoqProtocolError("el relay no respondió con SERVER_SETUP");
      }
      connectedSession.#onEvent({ type: "connected" });
      connectedSession.#controlLoop = connectedSession.#runControlLoop();
      connectedSession.#incomingLoop = connectedSession.#runIncomingLoop();
      void transport.closed.then(
        () => {
          if (!connectedSession.#closed) connectedSession.#fail(new Error("transporte cerrado"));
        },
        (cause: unknown) => {
          if (!connectedSession.#closed) connectedSession.#fail(cause);
        },
      );
      return connectedSession;
    } catch (cause: unknown) {
      signal?.removeEventListener("abort", abortPendingTransport);
      if (session) await session.close(0x03, "conexión fallida");
      else transport.close({ closeCode: 0x03, reason: "conexión fallida" });
      if (!transportReady && !isAbortError(cause)) throw new WebTransportTrustError();
      throw cause;
    }
  }

  subscribe(
    namespace: readonly string[],
    track: string,
    handler: ObjectHandler,
    deliveryClass: DeliveryClass = "control",
  ) {
    if (this.#closed) {
      return Promise.reject(new MoqProtocolError("la sesión MoQT está cerrada"));
    }
    const requestId = this.#nextRequestId;
    this.#nextRequestId += 2;
    return new Promise<number>((resolve, reject) => {
      this.#pending.set(requestId, { track, handler, deliveryClass, resolve, reject });
      this.#controlWriter.write(encodeSubscribe(requestId, namespace, track)).catch((cause: unknown) => {
        this.#pending.delete(requestId);
        reject(toError(cause));
      });
    });
  }

  close(code = 0, reason = "player detenido"): Promise<void> {
    if (this.#closePromise) return this.#closePromise;
    this.#closed = true;
    this.#abortController.abort(reason);
    this.#removeExternalAbort?.();
    this.#removeExternalAbort = null;
    for (const pending of this.#pending.values()) {
      pending.reject(new MoqProtocolError(reason));
    }
    this.#pending.clear();
    this.#earlyObjects.clear();
    this.#earlyObjectCount = 0;
    this.#earlyByteCount = 0;
    for (const queue of this.#handlers.values()) queue.close();
    this.#handlers.clear();
    this.#transport.close({ closeCode: code, reason });
    this.#closePromise = Promise.allSettled([
      this.#controlReader.cancel(reason),
      this.#incomingReader.cancel(reason),
      this.#controlWriter.close(),
      ...this.#activeStreams,
      ...(this.#controlLoop ? [this.#controlLoop] : []),
      ...(this.#incomingLoop ? [this.#incomingLoop] : []),
    ]).then(() => undefined);
    return this.#closePromise;
  }

  async #runControlLoop() {
    try {
      while (!this.#closed) {
        const message = await this.#controlReader.next();
        if (this.#closed) break;
        if (message.type === "subscribe-ok") {
          const pending = this.#pending.get(message.requestId);
          if (!pending) continue;
          this.#pending.delete(message.requestId);
          const queue = new TrackDeliveryQueue(
            pending.handler,
            pending.deliveryClass,
            (cause) => this.#handleDeliveryError(pending.deliveryClass, cause),
          );
          this.#handlers.set(message.trackAlias, queue);
          pending.resolve(message.trackAlias);
          this.#onEvent({ type: "subscribed", track: pending.track, alias: message.trackAlias });
          const early = this.#earlyObjects.get(message.trackAlias) ?? [];
          this.#removeEarlyQueue(message.trackAlias, early);
          // Do not await media handlers from the control loop: a catalog parse or
          // a decoder callback must never delay the next SUBSCRIBE_OK.
          for (const object of early) {
            this.#enqueueDelivery(message.trackAlias, queue, object);
          }
        } else if (message.type === "request-error") {
          const pending = this.#pending.get(message.requestId);
          if (!pending) continue;
          this.#pending.delete(message.requestId);
          pending.reject(new MoqProtocolError(`SUBSCRIBE rechazado (${message.errorCode}): ${message.reason}`));
        } else {
          throw new MoqProtocolError("SERVER_SETUP duplicado");
        }
      }
    } catch (cause: unknown) {
      if (!this.#closed) this.#fail(cause);
    }
  }

  async #runIncomingLoop() {
    try {
      while (!this.#closed) {
        if (this.#activeStreams.size >= MAX_ACTIVE_STREAMS) {
          await Promise.race(this.#activeStreams);
        }
        const { value: stream, done } = await this.#incomingReader.read();
        if (done || this.#closed) {
          if (!done) void stream.cancel("sesión cerrada").catch(() => undefined);
          break;
        }
        const task = this.#processStream(stream).finally(() => this.#activeStreams.delete(task));
        this.#activeStreams.add(task);
      }
    } catch (cause: unknown) {
      if (!this.#closed) this.#fail(cause);
    }
  }

  async #processStream(stream: ReadableStream<Uint8Array>) {
    try {
      for await (const object of readSubgroupStream(stream, this.#abortController.signal)) {
        if (this.#closed) return;
        const queue = this.#handlers.get(object.trackAlias);
        if (queue) {
          this.#enqueueDelivery(object.trackAlias, queue, object);
          continue;
        }
        if (this.#pending.size === 0) {
          this.#reportStreamDrop("unconfirmed-alias");
          continue;
        }
        if (!this.#queueEarlyObject(object)) {
          this.#fail(new MoqProtocolError("la cola temprana acotada se agotó"));
          return;
        }
      }
    } catch {
      if (!this.#closed) this.#reportStreamDrop("invalid-stream");
    }
  }

  #queueEarlyObject(object: MoqObject) {
    if (this.#pending.size === 0) return false;
    const existing = this.#earlyObjects.get(object.trackAlias);
    if (!existing && this.#earlyObjects.size >= MAX_EARLY_ALIASES) return false;
    if (
      this.#earlyObjectCount >= MAX_EARLY_OBJECTS ||
      this.#earlyByteCount + object.payload.byteLength > MAX_EARLY_BYTES
    ) {
      return false;
    }
    const queue = existing ?? [];
    queue.push(object);
    if (!existing) this.#earlyObjects.set(object.trackAlias, queue);
    this.#earlyObjectCount += 1;
    this.#earlyByteCount += object.payload.byteLength;
    return true;
  }

  #removeEarlyQueue(alias: number, objects: readonly MoqObject[]) {
    this.#earlyObjects.delete(alias);
    this.#earlyObjectCount = Math.max(0, this.#earlyObjectCount - objects.length);
    this.#earlyByteCount = Math.max(
      0,
      this.#earlyByteCount - objects.reduce((bytes, object) => bytes + object.payload.byteLength, 0),
    );
  }

  #enqueueDelivery(_alias: number, queue: TrackDeliveryQueue, object: MoqObject) {
    const result = queue.enqueue(object);
    if (result === "video-dropped" || result === "video-resynced") {
      this.#reportStreamDrop("video-pressure");
    } else if (result === "overflow") {
      this.#fail(new MoqProtocolError("una cola de Track acotada se agotó"));
    }
  }

  #reportStreamDrop(reason: "invalid-stream" | "unconfirmed-alias" | "video-pressure") {
    const now = performance.now();
    if (now - this.#lastDropEventAt < DROP_EVENT_INTERVAL_MS) return;
    this.#lastDropEventAt = now;
    this.#onEvent({ type: "stream-dropped", reason });
  }

  #fail(cause: unknown) {
    const error = toError(cause);
    this.#onEvent({ type: "error", error });
    void this.close(0x03, "sesión fallida");
  }

  #handleDeliveryError(deliveryClass: DeliveryClass, cause: unknown) {
    if (this.#closed) return;
    if (deliveryClass === "video") this.#reportStreamDrop("invalid-stream");
    else this.#fail(cause);
  }

  #linkExternalAbort(signal?: AbortSignal) {
    if (!signal) return;
    const abort = () => void this.close(0, "cancelado");
    signal.addEventListener("abort", abort, { once: true });
    this.#removeExternalAbort = () => signal.removeEventListener("abort", abort);
    if (signal.aborted) abort();
  }
}

export function decodeSha256Hex(value: string) {
  const normalized = value.trim().toLowerCase();
  if (!/^[0-9a-f]{64}$/.test(normalized)) {
    throw new MoqProtocolError("fingerprint SHA-256 inválido");
  }
  const bytes = new Uint8Array(32);
  for (let index = 0; index < bytes.length; index += 1) {
    bytes[index] = Number.parseInt(normalized.slice(index * 2, index * 2 + 2), 16);
  }
  return bytes;
}

function toError(cause: unknown) {
  return cause instanceof Error ? cause : new Error(String(cause));
}

function abortError() {
  const error = new Error("conexión cancelada");
  error.name = "AbortError";
  return error;
}

function isAbortError(cause: unknown) {
  return cause instanceof Error && cause.name === "AbortError";
}
