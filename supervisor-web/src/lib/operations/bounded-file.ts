import { open, type FileHandle } from "node:fs/promises";
import { OperationsDataError } from "./validation";

const READ_CHUNK_BYTES = 64 * 1024;

/** Opens, verifies and reads one descriptor, then closes it on every path. */
export async function readUtf8FileLimited(
  filePath: string,
  limit: number,
): Promise<{ text: string; modifiedAt: Date }> {
  if (!Number.isSafeInteger(limit) || limit < 1) throw new OperationsDataError("data-invalid");
  const handle = await open(filePath, "r");
  return readUtf8HandleLimited(handle, limit);
}

export async function readUtf8HandleLimited(
  handle: FileHandle,
  limit: number,
): Promise<{ text: string; modifiedAt: Date }> {
  try {
    const metadata = await handle.stat();
    if (!metadata.isFile() || metadata.size > limit) {
      throw new OperationsDataError("payload-excessive");
    }
    const decoder = new TextDecoder("utf-8", { fatal: true });
    let text = "";
    let bytesRead = 0;
    while (true) {
      const buffer = new Uint8Array(Math.min(READ_CHUNK_BYTES, limit - bytesRead + 1));
      const result = await handle.read(buffer, 0, buffer.byteLength, null);
      if (result.bytesRead === 0) break;
      bytesRead += result.bytesRead;
      if (bytesRead > limit) throw new OperationsDataError("payload-excessive");
      text += decoder.decode(buffer.subarray(0, result.bytesRead), { stream: true });
    }
    text += decoder.decode();
    return { text, modifiedAt: metadata.mtime };
  } catch (cause: unknown) {
    if (cause instanceof OperationsDataError) throw cause;
    throw new OperationsDataError("data-invalid");
  } finally {
    await handle.close();
  }
}
