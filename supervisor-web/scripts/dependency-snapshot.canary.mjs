import assert from "node:assert/strict";
import { mkdtemp, mkdir, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { assertDependencySnapshot, measureDependencySnapshot } from "./dependency-snapshot.mjs";

const root = await mkdtemp(join(tmpdir(), "teremoq-dependency-snapshot-"));
try {
  await mkdir(join(root, "pkg"));
  await writeFile(join(root, "pkg", "a.js"), "export default 1;\n");
  const first = await measureDependencySnapshot(root);
  assert.equal(first.inventory_files, 1);
  assertDependencySnapshot(await measureDependencySnapshot(root), first);
  await writeFile(join(root, "pkg", "a.js"), "export default 2;\n");
  const tampered = await measureDependencySnapshot(root);
  assert.throws(() => assertDependencySnapshot(tampered, first));
  assert.throws(() => assertDependencySnapshot(first, {
    ...first, total_bytes: first.total_bytes + 1,
  }));
  await symlink(join(root, "pkg"), join(root, "linked"), "junction");
  await assert.rejects(measureDependencySnapshot(root), /symlinks/);
} finally {
  await rm(root, { recursive: true, force: true });
}
console.log("dependency-snapshot-test: PASS");
