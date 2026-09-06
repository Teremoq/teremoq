import { describe, expect, it } from "vitest";
import { dirname, resolve } from "node:path";
import { verifyPackageSource } from "../../../scripts/verify-package-source.mjs";

const commit = "1".repeat(40);
const tree = "a".repeat(40);
const project = resolve("/repo/supervisor-web");
const root = dirname(project);

function runner(overrides: Record<string, string | Error> = {}) {
  return (args: string[]) => {
    const command = args.slice(2).join(" ");
    const value = overrides[command];
    if (value instanceof Error) throw value;
    if (value !== undefined) return value;
    if (command === "rev-parse --show-toplevel") return root;
    if (command === `rev-parse --verify ${commit}^{commit}`) return commit;
    if (command === "rev-parse HEAD") return commit;
    if (command === "status --porcelain=v1 --untracked-files=all") return "";
    if (command === `rev-parse ${commit}:supervisor-web`) return tree;
    throw new Error(`comando inesperado: ${command}`);
  };
}

describe("procedencia Git del paquete LAN", () => {
  it("acepta únicamente HEAD resoluble y checkout totalmente limpio", () => {
    expect(verifyPackageSource(project, commit, runner())).toEqual({
      root,
      sourceCommit: commit,
      sourceTree: tree,
    });
  });

  it("rechaza commit no resoluble", () => {
    expect(() => verifyPackageSource(project, commit, runner({
      [`rev-parse --verify ${commit}^{commit}`]: new Error("unknown revision"),
    }))).toThrow();
  });

  it("rechaza mismatch con HEAD", () => {
    expect(() => verifyPackageSource(project, commit, runner({
      "rev-parse HEAD": "2".repeat(40),
    }))).toThrow("no coincide con HEAD");
  });

  it.each([" M supervisor-web/README.md", "?? supervisor-web/nuevo.ts"])(
    "rechaza checkout sucio: %s",
    (status) => {
      expect(() => verifyPackageSource(project, commit, runner({
        "status --porcelain=v1 --untracked-files=all": status,
      }))).toThrow("debe estar limpio");
    },
  );
});
