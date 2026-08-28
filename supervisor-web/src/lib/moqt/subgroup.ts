import { AsyncByteReader, ByteCursor, MoqProtocolError } from "./binary";

export const MAX_OBJECT_BYTES = 4 * 1024 * 1024;
const MAX_STREAM_OVERHEAD = 64 * 1024;
const MAX_OBJECTS_PER_STREAM = 32;

export type MoqObject = {
  trackAlias: number;
  groupId: number;
  subgroupId: number;
  publisherPriority: number;
  objectIdDelta: number;
  streamObjectIndex: number;
  status: number | null;
  payload: Uint8Array;
};

export async function* readSubgroupStream(
  stream: ReadableStream<Uint8Array>,
  signal?: AbortSignal,
) {
  const limit = MAX_OBJECT_BYTES + MAX_STREAM_OVERHEAD;
  const reader = new AsyncByteReader(stream, limit, signal);
  const headerType = await reader.readVarInt();
  assertSupportedHeaderType(headerType);
  const trackAlias = await reader.readVarInt();
  const groupId = await reader.readVarInt();
  const subgroupId = hasSubgroupId(headerType) ? await reader.readVarInt() : 0;
  const publisherPriority = (await reader.readExact(1))[0];
  let objectCount = 0;

  while (true) {
    const objectIdDelta = await reader.readVarIntOrEof();
    if (objectIdDelta === null) return;
    if (objectCount >= MAX_OBJECTS_PER_STREAM) {
      throw new MoqProtocolError("el subgroup supera el máximo de Objects permitido");
    }
    objectCount += 1;
    if (hasExtensionHeaders(headerType)) {
      const extensionLength = await reader.readVarInt();
      if (extensionLength > MAX_STREAM_OVERHEAD) {
        throw new MoqProtocolError("extension headers demasiado grandes");
      }
      await reader.readExact(extensionLength);
    }
    const payloadLength = await reader.readVarInt();
    if (payloadLength > MAX_OBJECT_BYTES) {
      throw new MoqProtocolError(`Object supera ${MAX_OBJECT_BYTES} bytes`);
    }
    const status = payloadLength === 0 ? await reader.readVarInt() : null;
    yield {
      trackAlias,
      groupId,
      subgroupId,
      publisherPriority,
      objectIdDelta,
      streamObjectIndex: objectCount - 1,
      status,
      payload: await reader.readExact(payloadLength),
    };
  }
}

export function parseSubgroupStream(bytes: Uint8Array): MoqObject[] {
  const cursor = new ByteCursor(bytes);
  const headerType = cursor.readVarInt();
  assertSupportedHeaderType(headerType);

  const trackAlias = cursor.readVarInt();
  const groupId = cursor.readVarInt();
  const subgroupId = hasSubgroupId(headerType) ? cursor.readVarInt() : 0;
  const publisherPriority = cursor.readU8();
  const objects: MoqObject[] = [];

  while (cursor.remaining > 0) {
    if (objects.length >= MAX_OBJECTS_PER_STREAM) {
      throw new MoqProtocolError("el subgroup supera el máximo de Objects permitido");
    }
    const objectIdDelta = cursor.readVarInt();
    if (hasExtensionHeaders(headerType)) {
      const extensionLength = cursor.readVarInt();
      if (extensionLength > MAX_STREAM_OVERHEAD) {
        throw new MoqProtocolError("extension headers demasiado grandes");
      }
      cursor.readBytes(extensionLength);
    }
    const payloadLength = cursor.readVarInt();
    if (payloadLength > MAX_OBJECT_BYTES) {
      throw new MoqProtocolError(`Object supera ${MAX_OBJECT_BYTES} bytes`);
    }
    const status = payloadLength === 0 ? cursor.readVarInt() : null;
    objects.push({
      trackAlias,
      groupId,
      subgroupId,
      publisherPriority,
      objectIdDelta,
      streamObjectIndex: objects.length,
      status,
      payload: cursor.readBytes(payloadLength),
    });
  }

  return objects;
}

function assertSupportedHeaderType(headerType: number) {
  if (headerType < 0x10 || headerType > 0x1d || headerType === 0x16 || headerType === 0x17) {
    throw new MoqProtocolError(`stream de datos no soportado: 0x${headerType.toString(16)}`);
  }
}

function hasSubgroupId(headerType: number) {
  return headerType === 0x14 || headerType === 0x15 || headerType === 0x1c || headerType === 0x1d;
}

function hasExtensionHeaders(headerType: number) {
  return headerType % 2 === 1;
}
