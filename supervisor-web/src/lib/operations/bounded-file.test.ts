import type { FileHandle } from "node:fs/promises";
import { describe, expect, it } from "vitest";
import { readUtf8HandleLimited } from "./bounded-file";

describe("lector acotado del fixture local", () => {
  it("verifica y lee el mismo descriptor, limita en +1 y siempre lo cierra", async () => {
    const limit = 32;
    let produced = 0;
    let closed = false;
    const handle = {
      async stat() {
        return { isFile: () => true, size: limit, mtime: new Date("2026-08-28T12:00:00.000Z") };
      },
      async read(buffer: Uint8Array) {
        buffer.fill(0x78);
        produced += buffer.byteLength;
        return { bytesRead: buffer.byteLength, buffer };
      },
      async close() {
        closed = true;
      },
    } as unknown as FileHandle;

    await expect(readUtf8HandleLimited(handle, limit)).rejects.toThrow("payload-excessive");
    expect(produced).toBe(limit + 1);
    expect(closed).toBe(true);
  });

  it("cierra también cuando el descriptor no representa un fichero regular", async () => {
    let closed = false;
    const handle = {
      async stat() {
        return { isFile: () => false, size: 0, mtime: new Date() };
      },
      async close() {
        closed = true;
      },
    } as unknown as FileHandle;

    await expect(readUtf8HandleLimited(handle, 32)).rejects.toThrow("payload-excessive");
    expect(closed).toBe(true);
  });
});
