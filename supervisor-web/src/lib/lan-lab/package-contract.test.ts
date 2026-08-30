import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { describe, expect, it } from "vitest";

describe("contrato del paquete LAN", () => {
  const buildScript = readFileSync("scripts/build-lan-lab.mjs", "utf8");
  const packageScript = readFileSync("scripts/package-lan-lab.mjs", "utf8");
  const startScript = readFileSync("scripts/start-lan-lab.mjs", "utf8");
  const platformLauncher = readFileSync("scripts/teremoq-lan-platform.ps1");
  const launcherContract = readFileSync("lan-launcher.tsv", "utf8");
  const nextConfig = readFileSync("next.config.ts", "utf8");

  it("activa standalone únicamente durante el build LAN explícito", () => {
    expect(buildScript).toContain('TEREMOQ_LAN_LAB: "1"');
    expect(nextConfig).toContain('output: "standalone"');
    expect(nextConfig).toContain("isLanLabEnabled(process.env)");
  });

  it("empaqueta sólo el runtime trazado, estáticos necesarios y launcher local", () => {
    expect(packageScript).toContain('".next", "standalone"');
    expect(packageScript).toContain('".next", "static"');
    expect(packageScript).not.toContain('join(projectRoot, "public")');
    expect(packageScript).not.toContain("origin/main");
    expect(packageScript).not.toContain('join(projectRoot, "node_modules")');
    expect(packageScript).toContain("MAX_PACKAGE_BYTES");
    expect(packageScript).toContain("MANIFEST.sha256.json");
    expect(packageScript).toContain("fuera del checkout");
    expect(packageScript).toContain("PLATFORM_LAUNCHER_NAME");
    expect(packageScript).toContain("lan-launcher.tsv");
    expect(packageScript).toContain("MAX_LAUNCHER_CONTRACT_BYTES");
    expect(packageScript).toContain("EVIDENCE_VALIDATOR_NAME");
    expect(packageScript).toContain("package_version: packageVersion");
    expect(packageScript).toContain("source_commit: sourceCommit");
  });

  it("fija la UI empaquetada a loopback sin alterar TLS del relay", () => {
    expect(startScript).toContain('HOSTNAME: "127.0.0.1"');
    expect(startScript).toContain('TEREMOQ_LAN_LAB: "1"');
    expect(startScript).not.toContain("NODE_TLS_REJECT_UNAUTHORIZED");
  });

  it("versiona un contrato cerrado y trazable para Platform", () => {
    expect(Buffer.byteLength(launcherContract, "utf8")).toBeLessThanOrEqual(4_096);
    const entries = launcherContract.trimEnd().split("\n").map((line) => line.split("\t"));
    expect(entries).toHaveLength(9);
    expect(Object.fromEntries(entries)).toEqual({
      schema_version: "1",
      launcher_relative_path: "teremoq-lan-platform.ps1",
      launcher_sha256: createHash("sha256").update(platformLauncher).digest("hex"),
      actions: "start,status,stop,collect",
      levels: "1,5,10,25",
      max_clients: "25",
      network_contract: "outbound_udp_14433_only",
      loopback_http_only: "true",
      source_commit: "<required-by-package-lan>",
    });
  });

  it("requiere source_commit canónico y lo inserta en contrato y manifest", () => {
    const missing = spawnSync(process.execPath, [
      "scripts/package-lan-lab.mjs", "--output", "/tmp/teremoq-package-missing-source",
    ], { encoding: "utf8" });
    expect(missing.status).not.toBe(0);
    expect(missing.stderr).toContain("--source-commit");

    const invalid = spawnSync(process.execPath, [
      "scripts/package-lan-lab.mjs", "--output", "/tmp/teremoq-package-invalid-source",
      "--source-commit", "ABC",
    ], { encoding: "utf8" });
    expect(invalid.status).not.toBe(0);
    expect(invalid.stderr).toContain("40 hex");
    expect(packageScript).toContain("`source_commit\\t${sourceCommit}`");
  });

  it("launcher valida parámetros, hash, fingerprint y rutas antes de actuar", () => {
    const source = platformLauncher.toString("utf8");
    for (const parameter of [
      "$Action", "$RunId", "$Level", "$VersionPath", "$FingerprintPath", "$EvidenceDirectory",
    ]) {
      expect(source).toContain(parameter);
    }
    expect(source).toContain('[ValidateSet("start", "status", "stop", "collect")]');
    expect(source).toContain("[ValidateSet(1, 5, 10, 25)]");
    expect(source).toContain("Get-FileHash");
    expect(source).toContain('HOSTNAME = "127.0.0.1"');
    expect(source).toContain("VERSION.tsv canónico exterior al paquete");
    expect(source).toContain("$Version.source_commit -cne $Package.source_commit");
    expect(source).toContain("$Version.moq_url -cne $LocalConfig.relay_url");
    expect(source).toContain("$Version.player_evidence -cne \"not_measured\"");
    expect(source).toContain("$Version.load_launcher_status -cne \"ready\"");
    expect(source).not.toContain("artifact_url");
    expect(source).toContain("Get-Command node -CommandType Application");
    expect(source).toContain("ElapsedMilliseconds -lt 15000");
    expect(source).toContain('GetAsync("http://127.0.0.1:3000/")');
    expect(source).toContain("se rechaza terminar un PID reutilizado");
    expect(source).toContain("El inventario del player contiene extras o ausencias");
    expect(source).toContain("valid_user_export_not_attested");
    expect(source).not.toContain("Invoke-WebRequest");
    expect(source).not.toContain("NODE_TLS_REJECT_UNAUTHORIZED");
  });
});
