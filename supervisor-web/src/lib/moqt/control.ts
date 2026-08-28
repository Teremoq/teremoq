import {
  AsyncByteReader,
  ByteCursor,
  ByteWriter,
  MoqProtocolError,
} from "./binary";

const textEncoder = new TextEncoder();
const textDecoder = new TextDecoder("utf-8", { fatal: true });

export const CONTROL_LIMIT = 65_535;

export type ServerSetup = {
  type: "server-setup";
  maxRequestId: number | null;
};

export type SubscribeOk = {
  type: "subscribe-ok";
  requestId: number;
  trackAlias: number;
};

export type RequestError = {
  type: "request-error";
  requestId: number;
  errorCode: number;
  retryInterval: number;
  reason: string;
};

export type ControlMessage = ServerSetup | SubscribeOk | RequestError;

export class ControlReader {
  readonly #reader: AsyncByteReader;

  constructor(stream: ReadableStream<Uint8Array>, signal?: AbortSignal) {
    this.#reader = new AsyncByteReader(stream, CONTROL_LIMIT * 2, signal);
  }

  async next(): Promise<ControlMessage> {
    const messageType = await this.#reader.readVarInt();
    const length = await this.#reader.readU16();
    if (length > CONTROL_LIMIT) {
      throw new MoqProtocolError("mensaje de control demasiado grande");
    }
    return parseControlMessage(messageType, await this.#reader.readExact(length));
  }

  cancel(reason: string) {
    return this.#reader.cancel(reason);
  }
}

export function encodeClientSetup(maxRequestId = 100) {
  const params = new ByteWriter();
  params.writeVarInt(1);
  params.writeVarInt(0x02);
  params.writeVarInt(maxRequestId);
  return frameControlMessage(0x20, params.toUint8Array());
}

export function encodeSubscribe(
  requestId: number,
  namespace: readonly string[],
  trackName: string,
) {
  if (namespace.length < 1 || namespace.length > 32) {
    throw new MoqProtocolError("el namespace debe contener entre 1 y 32 campos");
  }
  const payload = new ByteWriter();
  payload.writeVarInt(requestId);
  payload.writeVarInt(namespace.length);
  for (const field of namespace) {
    const encoded = textEncoder.encode(field);
    if (encoded.byteLength === 0) {
      throw new MoqProtocolError("los campos del namespace no pueden estar vacíos");
    }
    payload.writePrefixedBytes(encoded);
  }
  payload.writePrefixedBytes(textEncoder.encode(trackName));
  payload.writeVarInt(0);
  return frameControlMessage(0x03, payload.toUint8Array());
}

export function parseControlMessage(messageType: number, payload: Uint8Array): ControlMessage {
  const cursor = new ByteCursor(payload);
  switch (messageType) {
    case 0x21: {
      const params = readCountedKeyValuePairs(cursor);
      assertConsumed(cursor, "SERVER_SETUP");
      return {
        type: "server-setup",
        maxRequestId: params.get(0x02)?.integer ?? null,
      };
    }
    case 0x04: {
      const requestId = cursor.readVarInt();
      const trackAlias = cursor.readVarInt();
      readCountedKeyValuePairs(cursor);
      readTrailingKeyValuePairs(cursor);
      return { type: "subscribe-ok", requestId, trackAlias };
    }
    case 0x05: {
      const requestId = cursor.readVarInt();
      const errorCode = cursor.readVarInt();
      const retryInterval = cursor.readVarInt();
      const reason = textDecoder.decode(cursor.readBytes(cursor.readVarInt()));
      assertConsumed(cursor, "REQUEST_ERROR");
      return { type: "request-error", requestId, errorCode, retryInterval, reason };
    }
    default:
      throw new MoqProtocolError(`mensaje de control draft-16 no soportado: 0x${messageType.toString(16)}`);
  }
}

type KeyValue = { integer?: number; bytes?: Uint8Array };

function readCountedKeyValuePairs(cursor: ByteCursor) {
  const count = cursor.readVarInt();
  if (count > 128) {
    throw new MoqProtocolError("demasiados parámetros MoQT");
  }
  return readKeyValuePairs(cursor, count);
}

function readTrailingKeyValuePairs(cursor: ByteCursor) {
  return readKeyValuePairs(cursor, null);
}

function readKeyValuePairs(cursor: ByteCursor, count: number | null) {
  const result = new Map<number, KeyValue>();
  let previousType = 0;
  let read = 0;
  while (count === null ? cursor.remaining > 0 : read < count) {
    const absoluteType = previousType + cursor.readVarInt();
    if (!Number.isSafeInteger(absoluteType) || absoluteType < previousType) {
      throw new MoqProtocolError("delta KVP inválido");
    }
    const value =
      absoluteType % 2 === 0
        ? { integer: cursor.readVarInt() }
        : { bytes: cursor.readBytes(cursor.readVarInt()) };
    result.set(absoluteType, value);
    previousType = absoluteType;
    read += 1;
  }
  return result;
}

function frameControlMessage(messageType: number, payload: Uint8Array) {
  if (payload.byteLength > CONTROL_LIMIT) {
    throw new MoqProtocolError("payload de control demasiado grande");
  }
  const message = new ByteWriter();
  message.writeVarInt(messageType);
  message.writeU16(payload.byteLength);
  message.writeBytes(payload);
  return message.toUint8Array();
}

function assertConsumed(cursor: ByteCursor, name: string) {
  if (cursor.remaining !== 0) {
    throw new MoqProtocolError(`${name} contiene bytes finales inesperados`);
  }
}
