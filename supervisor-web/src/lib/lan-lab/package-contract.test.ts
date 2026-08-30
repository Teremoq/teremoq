import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

describe("contrato del paquete LAN", () => {
  const buildScript = readFileSync("scripts/build-lan-lab.mjs", "utf8");
  const packageScript = readFileSync("scripts/package-lan-lab.mjs", "utf8");
  const startScript = readFileSync("scripts/start-lan-lab.mjs", "utf8");
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
  });

  it("fija la UI empaquetada a loopback sin alterar TLS del relay", () => {
    expect(startScript).toContain('HOSTNAME: "127.0.0.1"');
    expect(startScript).toContain('TEREMOQ_LAN_LAB: "1"');
    expect(startScript).not.toContain("NODE_TLS_REJECT_UNAUTHORIZED");
  });
});
