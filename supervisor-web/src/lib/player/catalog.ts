import { MoqProtocolError } from "../moqt/binary";

export type CatalogVideoTrack = {
  name: string;
  codec: string;
  width: number;
  height: number;
  initialization: Uint8Array;
};

export type CatalogVideoTrackName = "0-video-hq" | "1-video-lq";

export function parseVideoCatalog(
  payload: Uint8Array,
  requestedTrack: CatalogVideoTrackName = "0-video-hq",
): CatalogVideoTrack | null {
  let decoded: unknown;
  try {
    decoded = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(payload)) as unknown;
  } catch (cause: unknown) {
    throw new MoqProtocolError(`catálogo MSF inválido: ${toMessage(cause)}`);
  }
  if (!isRecord(decoded) || decoded.version !== 1 || !Array.isArray(decoded.tracks)) {
    throw new MoqProtocolError("catálogo MSF v1 esperado");
  }
  const track = decoded.tracks.find(
    (candidate: unknown) =>
      isRecord(candidate) &&
      candidate.name === requestedTrack &&
      candidate.packaging === "cmaf" &&
      candidate.role === "video",
  );
  if (track === undefined) return null;
  if (
    !isRecord(track) ||
    typeof track.name !== "string" ||
    typeof track.codec !== "string" ||
    typeof track.width !== "number" ||
    typeof track.height !== "number" ||
    typeof track.initData !== "string"
  ) {
    throw new MoqProtocolError(`Track ${requestedTrack} contiene metadatos CMAF inválidos`);
  }
  if (!track.codec.startsWith("avc1.") && !track.codec.startsWith("avc3.")) {
    throw new MoqProtocolError(`codec no soportado por esta PoC: ${track.codec}`);
  }
  const initialization = decodeBase64(track.initData);
  if (initialization.byteLength === 0 || initialization.byteLength > 4 * 1024 * 1024) {
    throw new MoqProtocolError("initData CMAF vacío o fuera de límite");
  }
  return {
    name: track.name,
    codec: track.codec,
    width: track.width,
    height: track.height,
    initialization,
  };
}

function decodeBase64(value: string) {
  try {
    const binary = atob(value);
    const result = new Uint8Array(binary.length);
    for (let index = 0; index < binary.length; index += 1) {
      result[index] = binary.charCodeAt(index);
    }
    return result;
  } catch (cause: unknown) {
    throw new MoqProtocolError(`initData Base64 inválido: ${toMessage(cause)}`);
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

function toMessage(cause: unknown) {
  return cause instanceof Error ? cause.message : String(cause);
}
