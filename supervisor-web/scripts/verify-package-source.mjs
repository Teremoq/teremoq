import { execFileSync } from "node:child_process";
import { dirname, resolve } from "node:path";

export function verifyPackageSource(
  projectRoot,
  sourceCommit,
  runGit = (args) => execFileSync("git", args, { encoding: "utf8" }).trim(),
) {
  if (!/^[0-9a-f]{40}$/.test(sourceCommit)) throw new Error("source_commit inválido");
  const root = resolve(runGit(["-C", projectRoot, "rev-parse", "--show-toplevel"]));
  if (dirname(resolve(projectRoot)) !== root) {
    throw new Error("supervisor-web no está en la raíz Git esperada");
  }
  const resolved = runGit(["-C", root, "rev-parse", "--verify", `${sourceCommit}^{commit}`]);
  if (resolved !== sourceCommit) throw new Error("source_commit no es un commit resoluble exacto");
  const head = runGit(["-C", root, "rev-parse", "HEAD"]);
  if (head !== sourceCommit) throw new Error("--source-commit no coincide con HEAD");
  const status = runGit(["-C", root, "status", "--porcelain=v1", "--untracked-files=all"]);
  if (status !== "") throw new Error("el checkout Git debe estar limpio antes de empaquetar");
  const sourceTree = runGit(["-C", root, "rev-parse", `${sourceCommit}:supervisor-web`]);
  if (!/^[0-9a-f]{40}$/.test(sourceTree)) {
    throw new Error("árbol supervisor-web inválido");
  }
  return Object.freeze({ root, sourceCommit, sourceTree });
}
