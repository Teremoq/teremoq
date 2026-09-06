import { describe, expect, it } from "vitest";
import {
  BUILD_PROVENANCE_KEYS,
  normalizeEmptyServerReferenceManifests,
  normalizePrerenderManifest,
  normalizeRequiredServerFiles,
  normalizeStandaloneServer,
  parseBuildProvenance,
  serializeBuildProvenance,
} from "../../../scripts/lan-build-provenance.mjs";

const valid = {
  schema_version: 1,
  player_identity: `sha256:${"1".repeat(64)}`,
  player_version: "0.1.0",
  config_schema_version: 1,
  source_tree: "2".repeat(40),
  package_lock_sha256: "3".repeat(64),
  package_json_sha256: "4".repeat(64),
  node_version: "v22.14.0",
  npm_version: "10.9.2",
  build_mode: "lan-standalone",
};

describe("sello de procedencia del build LAN", () => {
  it("serializa y valida el contrato cerrado exacto", () => {
    const parsed = parseBuildProvenance(serializeBuildProvenance(valid), valid);
    expect(parsed).toEqual(valid);
    expect(Object.keys(parsed)).toEqual(BUILD_PROVENANCE_KEYS);
  });

  it.each([
    ["campo desconocido", { ...valid, extra: true }],
    ["campo ausente", Object.fromEntries(Object.entries(valid).slice(0, -1))],
    ["identidad inválida", { ...valid, player_identity: "sha256:ABC" }],
    ["Node incorrecto", { ...valid, node_version: "v20.18.0" }],
    ["npm incorrecto", { ...valid, npm_version: "11.0.0" }],
  ])("rechaza %s", (_label, value) => {
    expect(() => parseBuildProvenance(JSON.stringify(value), valid)).toThrow();
  });

  it("rechaza un build válido pero producido por otro árbol", () => {
    expect(() => parseBuildProvenance(
      serializeBuildProvenance(valid),
      { ...valid, source_tree: "9".repeat(40) },
    )).toThrow("no coincide");
  });

  it("normaliza sólo el metadata Draft/Preview aleatorio de Next 16", () => {
    const manifest = (id: string, signing: string, encryption: string) => JSON.stringify({
      version: 4,
      routes: {},
      preview: {
        previewModeId: id,
        previewModeSigningKey: signing,
        previewModeEncryptionKey: encryption,
      },
    });
    const first = normalizePrerenderManifest(
      manifest("1".repeat(32), "2".repeat(64), "3".repeat(64)),
      valid.player_identity,
    );
    const second = normalizePrerenderManifest(
      manifest("4".repeat(32), "5".repeat(64), "6".repeat(64)),
      valid.player_identity,
    );
    expect(first).toBe(second);
    expect(first).not.toContain("1".repeat(32));
  });

  it.each([
    ["preview extra", { previewModeId: "1".repeat(32), previewModeSigningKey: "2".repeat(64), previewModeEncryptionKey: "3".repeat(64), extra: true }],
    ["preview ausente", { previewModeId: "1".repeat(32), previewModeSigningKey: "2".repeat(64) }],
    ["longitud inválida", { previewModeId: "1", previewModeSigningKey: "2".repeat(64), previewModeEncryptionKey: "3".repeat(64) }],
  ])("rechaza prerender %s", (_label, preview) => {
    expect(() => normalizePrerenderManifest(JSON.stringify({ preview }), valid.player_identity)).toThrow();
  });

  it("elimina sólo los cuatro paths absolutos fijados por Next 16", () => {
    const required = (root: string) => JSON.stringify({
      version: 1,
      config: {
        outputFileTracingRoot: root,
        repoRoot: root,
        turbopack: { root },
      },
      appDir: root,
      files: [],
      ignore: [],
    });
    const first = normalizeRequiredServerFiles(required("/build/a/supervisor-web"), "/build/a/supervisor-web");
    const second = normalizeRequiredServerFiles(required("/build/b/supervisor-web"), "/build/b/supervisor-web");
    expect(first).toBe(second);
    expect(first).not.toContain("/build/");
  });

  it("rechaza paths Next ausentes o una aparición local inesperada", () => {
    const root = "/build/a/supervisor-web";
    expect(() => normalizeRequiredServerFiles(JSON.stringify({ config: {}, appDir: root }), root)).toThrow();
    expect(() => normalizeRequiredServerFiles(JSON.stringify({
      config: { outputFileTracingRoot: root, repoRoot: root, turbopack: { root } },
      appDir: root,
      unexpected: root,
    }), root)).toThrow("path local inesperado");
  });

  it("normaliza manifests Server Actions sólo si ambos concuerdan y están vacíos", () => {
    const jsonFor = (key: string) => JSON.stringify({
      node: {}, edge: {}, encryptionKey: key,
    }, null, 2);
    const normalize = (key: string) => {
      const json = jsonFor(key);
      return normalizeEmptyServerReferenceManifests(
        json,
        `self.__RSC_SERVER_MANIFEST=${JSON.stringify(json)}`,
        valid.player_identity,
      );
    };
    expect(normalize("A".repeat(43) + "=")).toEqual(normalize("B".repeat(43) + "="));
  });

  it("rechaza Server Actions presentes o wrapper JS discordante", () => {
    const json = JSON.stringify({
      node: { action: {} }, edge: {}, encryptionKey: "A".repeat(43) + "=",
    }, null, 2);
    expect(() => normalizeEmptyServerReferenceManifests(
      json, `self.__RSC_SERVER_MANIFEST=${JSON.stringify(json)}`, valid.player_identity,
    )).toThrow("no está vacío");
    const empty = JSON.stringify({ node: {}, edge: {}, encryptionKey: "A".repeat(43) + "=" }, null, 2);
    expect(() => normalizeEmptyServerReferenceManifests(
      empty, "self.__RSC_SERVER_MANIFEST=\"forged\"", valid.player_identity,
    )).toThrow("no coinciden");
  });

  it("normaliza el nextConfig embebido en standalone sin conservar el worktree", () => {
    const server = (root: string) => [
      "const path = require('path')",
      `const nextConfig = ${JSON.stringify({
        outputFileTracingRoot: root,
        repoRoot: root,
        turbopack: { root },
        output: "standalone",
      })}`,
      "",
      "process.env.__NEXT_PRIVATE_STANDALONE_CONFIG = JSON.stringify(nextConfig)",
      "require('next')",
    ].join("\n");
    expect(normalizeStandaloneServer(server("/build/a"), "/build/a"))
      .toBe(normalizeStandaloneServer(server("/build/b"), "/build/b"));
  });

  it("rechaza plantilla standalone discordante y paths inesperados", () => {
    expect(() => normalizeStandaloneServer("const nextConfig = {}", "/build/a")).toThrow();
    const root = "/build/a";
    const config = JSON.stringify({
      outputFileTracingRoot: root,
      repoRoot: root,
      turbopack: { root },
      unexpected: root,
    });
    expect(() => normalizeStandaloneServer(
      `const nextConfig = ${config}\n\nprocess.env.__NEXT_PRIVATE_STANDALONE_CONFIG = JSON.stringify(nextConfig)`,
      root,
    )).toThrow("path local inesperado");
  });
});
