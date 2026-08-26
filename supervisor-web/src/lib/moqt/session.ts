import { ControlReader, encodeClientSetup, encodeSubscribe } from "./control";
import { MoqProtocolError } from "./binary";
import { MoqObject, readSubgroupStream } from "./subgroup";

// One ordered Subgroup remains open per active Track/Group. Eight readers cover
// the four logical Tracks plus bounded Group transitions without allowing a
// peer to allocate unbounded stream parser state.
const MAX_ACTIVE_STREAMS = 8;
const MAX_EARLY_ALIASES = 8;
const MAX_EARLY_OBJECTS = 96;
const MAX_EARLY_BYTES = 8 * 1024 * 1024;
const DROP_EVENT_INTERVAL_MS = 500;

export type ObjectHandler = (object: MoqObject) => void | Promise<void>;

export type SessionEvent =
  | { type: "connected" }
  | { type: "subscribed"; track: string; alias: number }
  | { type: "stream-dropped"; reason: string }
  | { type: "error"; message: string };

type PendingSubscription = {
  track: string;
  handler: ObjectHandler;
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
  readonly #pending = new Map<number, PendingSubscription>();
  readonly #handlers = new Map<number, ObjectHandler>();
  readonly #earlyObjects = new Map<number, MoqObject[]>();
  readonly #deliveryTails = new Map<number, Promise<void>>();
  readonly #activeStreams = new Set<Promise<void>>();
  #nextRequestId = 0;
  #earlyObjectCount = 0;
  #earlyByteCount = 0;
  #lastDropEventAt = Number.NEGATIVE_INFINITY;
  #closed = false;

  private constructor(
    transport: WebTransport,
    control: WebTransportBidirectionalStream,
    onEvent: (event: SessionEvent) => void,
  ) {
    this.#transport = transport;
    this.#control = control;
    this.#controlReader = new ControlReader(
      control.readable as ReadableStream<Uint8Array>,
    );
    this.#controlWriter = (
      control.writable as WritableStream<Uint8Array>
    ).getWriter();
    this.#incomingReader = (
      transport.incomingUnidirectionalStreams as ReadableStream<ReadableStream<Uint8Array>>
    ).getReader();
    this.#onEvent = onEvent;
  }

  static async connect(
    url: string,
    certificateSha256: Uint8Array,
    onEvent: (event: SessionEvent) => void,
  ) {
    if (certificateSha256.byteLength !== 32) {
      throw new MoqProtocolError("el fingerprint SHA-256 debe contener 32 bytes");
    }
    const certificateBuffer = new ArrayBuffer(32);
    new Uint8Array(certificateBuffer).set(certificateSha256);
    const transport = new WebTransport(url, {
      congestionControl: "low-latency",
      serverCertificateHashes: [
        { algorithm: "sha-256", value: certificateBuffer },
      ],
    });
    await transport.ready;
    const control = await transport.createBidirectionalStream();
    const session = new MoqSession(transport, control, onEvent);
    await session.#controlWriter.write(encodeClientSetup());
    const setup = await session.#controlReader.next();
    if (setup.type !== "server-setup") {
      session.close(0x03, "SERVER_SETUP esperado");
      throw new MoqProtocolError("el relay no respondió con SERVER_SETUP");
    }
    session.#onEvent({ type: "connected" });
    void session.#runControlLoop();
    void session.#runIncomingLoop();
    void transport.closed.then(
      (info) => {
        if (!session.#closed) {
          const detail = info.reason || `código ${info.closeCode}`;
          session.#fail(new MoqProtocolError(`WebTransport cerrado: ${detail}`));
        }
      },
      (cause: unknown) => {
        if (!session.#closed) session.#fail(cause);
      },
    );
    return session;
  }

  subscribe(namespace: readonly string[], track: string, handler: ObjectHandler) {
    if (this.#closed) {
      return Promise.reject(new MoqProtocolError("la sesión MoQT está cerrada"));
    }
    const requestId = this.#nextRequestId;
    this.#nextRequestId += 2;
    return new Promise<number>((resolve, reject) => {
      this.#pending.set(requestId, { track, handler, resolve, reject });
      this.#controlWriter.write(encodeSubscribe(requestId, namespace, track)).catch((cause: unknown) => {
        this.#pending.delete(requestId);
        reject(toError(cause));
      });
    });
  }

  close(code = 0, reason = "player detenido") {
    if (this.#closed) return;
    this.#closed = true;
    for (const pending of this.#pending.values()) {
      pending.reject(new MoqProtocolError(reason));
    }
    this.#pending.clear();
    this.#earlyObjects.clear();
    this.#earlyObjectCount = 0;
    this.#earlyByteCount = 0;
    void this.#controlReader.cancel(reason).catch(() => undefined);
    void this.#incomingReader.cancel(reason).catch(() => undefined);
    void this.#controlWriter.close().catch(() => undefined);
    this.#transport.close({ closeCode: code, reason });
  }

  async #runControlLoop() {
    try {
      while (!this.#closed) {
        const message = await this.#controlReader.next();
        if (message.type === "subscribe-ok") {
          const pending = this.#pending.get(message.requestId);
          if (!pending) continue;
          this.#pending.delete(message.requestId);
          this.#handlers.set(message.trackAlias, pending.handler);
          pending.resolve(message.trackAlias);
          this.#onEvent({ type: "subscribed", track: pending.track, alias: message.trackAlias });
          const early = this.#earlyObjects.get(message.trackAlias) ?? [];
          this.#removeEarlyQueue(message.trackAlias, early);
          // Do not await media handlers from the control loop: a catalog parse or
          // a decoder callback must never delay the next SUBSCRIBE_OK.
          for (const object of early) {
            this.#enqueueDelivery(message.trackAlias, pending.handler, object);
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
        if (done) break;
        const task = this.#processStream(stream).finally(() => this.#activeStreams.delete(task));
        this.#activeStreams.add(task);
      }
    } catch (cause: unknown) {
      if (!this.#closed) this.#fail(cause);
    }
  }

  async #processStream(stream: ReadableStream<Uint8Array>) {
    try {
      for await (const object of readSubgroupStream(stream)) {
        const handler = this.#handlers.get(object.trackAlias);
        if (handler) {
          this.#enqueueDelivery(object.trackAlias, handler, object);
          continue;
        }
        if (!this.#queueEarlyObject(object)) {
          this.#reportStreamDrop("alias aún no confirmado");
          continue;
        }
      }
    } catch (cause: unknown) {
      this.#reportStreamDrop(toError(cause).message);
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

  #enqueueDelivery(alias: number, handler: ObjectHandler, object: MoqObject) {
    const previous = this.#deliveryTails.get(alias) ?? Promise.resolve();
    const current = previous
      .then(() => handler(object))
      .catch((cause: unknown) => this.#reportStreamDrop(toError(cause).message));
    this.#deliveryTails.set(alias, current);
    void current.finally(() => {
      if (this.#deliveryTails.get(alias) === current) this.#deliveryTails.delete(alias);
    });
  }

  #reportStreamDrop(reason: string) {
    const now = performance.now();
    if (now - this.#lastDropEventAt < DROP_EVENT_INTERVAL_MS) return;
    this.#lastDropEventAt = now;
    this.#onEvent({ type: "stream-dropped", reason });
  }

  #fail(cause: unknown) {
    const error = toError(cause);
    this.#onEvent({ type: "error", message: error.message });
    this.close(0x03, error.message.slice(0, 128));
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
