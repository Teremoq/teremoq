import { createHash } from "node:crypto";
import { lstat, readFile, readdir } from "node:fs/promises";
import { join, relative, resolve } from "node:path";

const MAX_FILES = 200_000;
const MAX_TOTAL_BYTES = 1_073_741_824;

export async function measureDependencySnapshot(root) {
  const absolute = resolve(root);
  const entries = [];
  const limits = { files: 0, bytes: 0 };
  await walk(absolute, absolute, entries, limits);
  entries.sort((left, right) => left.path < right.path ? -1 : left.path > right.path ? 1 : 0);
  const digest = createHash("sha256");
  for (const entry of entries) {
    digest.update(`${entry.path}\0${entry.mode}\0${entry.bytes}\0${entry.sha256}\n`);
  }
  if (entries.length < 1) throw new Error("snapshot de dependencias vacío");
  return Object.freeze({
    inventory_files: entries.length,
    total_bytes: limits.bytes,
    inventory_sha256: digest.digest("hex"),
  });
}

export function assertDependencySnapshot(measured, evidence) {
  if (measured.inventory_files !== evidence.inventory_files ||
      measured.total_bytes !== evidence.total_bytes ||
      measured.inventory_sha256 !== evidence.inventory_sha256) {
    throw new Error("snapshot de dependencias no coincide con evidencia");
  }
}

async function walk(root, directory, entries, limits) {
  const children = await readdir(directory, { withFileTypes: true });
  for (const child of children) {
    const path = join(directory, child.name);
    if (child.isSymbolicLink()) throw new Error("snapshot de dependencias no admite symlinks");
    if (child.isDirectory()) {
      await walk(root, path, entries, limits);
      continue;
    }
    if (!child.isFile()) throw new Error("snapshot de dependencias contiene tipo no regular");
    const stat = await lstat(path);
    limits.files += 1;
    limits.bytes += stat.size;
    if (limits.files > MAX_FILES || limits.bytes > MAX_TOTAL_BYTES || stat.size > 268_435_456) {
      throw new Error("snapshot de dependencias supera límites");
    }
    const bytes = await readFile(path);
    if (!stat.isFile() || stat.isSymbolicLink() || bytes.byteLength !== stat.size) {
      throw new Error("snapshot de dependencias cambió durante lectura");
    }
    const relativePath = relative(root, path).replaceAll("\\", "/");
    if (relativePath.length < 1 || relativePath.length > 1_024 || relativePath.includes("\0")) {
      throw new Error("path de dependencia fuera de contrato");
    }
    entries.push({
      path: relativePath,
      mode: stat.mode & 0o777,
      bytes: bytes.byteLength,
      sha256: createHash("sha256").update(bytes).digest("hex"),
    });
  }
}
