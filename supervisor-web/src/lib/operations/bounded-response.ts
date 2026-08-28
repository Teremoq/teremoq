import { OperationsDataError } from "./validation";

const READ_CHUNK_BYTES = 64 * 1024;

type BodyReader =
  | { mode: "byob"; reader: ReadableStreamBYOBReader }
  | { mode: "default"; reader: ReadableStreamDefaultReader<Uint8Array> };

/** Read at most limit + 1 bytes and cancel immediately on overflow. */
export async function readResponseTextLimited(response: Response, limit: number): Promise<string> {
  if (!Number.isSafeInteger(limit) || limit < 1) throw new OperationsDataError("data-invalid");
  const declaredLength = response.headers.get("content-length");
  if (declaredLength !== null) {
    if (!/^(0|[1-9]\d*)$/.test(declaredLength)) {
      cancelUnlocked(response.body);
      throw new OperationsDataError("data-invalid");
    }
    const declaredBytes = Number(declaredLength);
    if (!Number.isSafeInteger(declaredBytes)) {
      cancelUnlocked(response.body);
      throw new OperationsDataError("data-invalid");
    }
    if (declaredBytes > limit) {
      cancelUnlocked(response.body);
      throw new OperationsDataError("payload-excessive");
    }
  }
  if (response.body === null) return "";

  const source = acquireReader(response.body);
  const decoder = new TextDecoder("utf-8", { fatal: true });
  let text = "";
  let bytesRead = 0;
  try {
    while (true) {
      const result = source.mode === "byob"
        ? await source.reader.read(new Uint8Array(Math.min(READ_CHUNK_BYTES, limit - bytesRead + 1)))
        : await source.reader.read();
      if (result.done) break;
      const chunk = result.value;
      if (!(chunk instanceof Uint8Array) || chunk.byteLength === 0) {
        cancelReader(source.reader);
        throw new OperationsDataError("data-invalid");
      }
      bytesRead += chunk.byteLength;
      if (bytesRead > limit) {
        cancelReader(source.reader);
        throw new OperationsDataError("payload-excessive");
      }
      text += decoder.decode(chunk, { stream: true });
    }
    text += decoder.decode();
    return text;
  } catch (cause: unknown) {
    cancelReader(source.reader);
    if (cause instanceof OperationsDataError) throw cause;
    throw new OperationsDataError("data-invalid");
  } finally {
    source.reader.releaseLock();
  }
}

function acquireReader(body: ReadableStream<Uint8Array>): BodyReader {
  try {
    return { mode: "byob", reader: body.getReader({ mode: "byob" }) };
  } catch {
    return { mode: "default", reader: body.getReader() };
  }
}

function cancelReader(reader: ReadableStreamBYOBReader | ReadableStreamDefaultReader<Uint8Array>) {
  void reader.cancel("payload-excessive").catch(() => undefined);
}

function cancelUnlocked(body: ReadableStream<Uint8Array> | null) {
  if (body !== null) void body.cancel("payload-excessive").catch(() => undefined);
}
