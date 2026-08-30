import { readFileSync } from "node:fs";
import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";
import type { PlayerDeployment } from "@/lib/lan-lab/config";
import { LanLoadGeneratorPanel } from "./lan-load-generator";

const deployment: PlayerDeployment = {
  mode: "lan-lab",
  environmentLabel: "LAN LAB / NO PRODUCCIÓN",
  configurationSource: "local-environment",
  configurationStatus: "available",
  metricsStatus: "not_measured",
  operationsAvailable: false,
  configuration: {
    schema_version: 1,
    relay_url: "https://192.168.10.20:14433/watch",
    fingerprint_sha256: "a".repeat(64),
    prefix_length: 24,
    namespace: "teremoq/live",
    run_id: "lan-test-01",
    source_commit: "1".repeat(40),
  },
};

describe("superficie de carga ligera LAN", () => {
  it("ofrece sólo 5/10/25, stop y exportación local con semántica nativa", () => {
    const html = renderToStaticMarkup(
      <LanLoadGeneratorPanel deployment={deployment} initialLevel={null} />,
    );
    expect(html).toContain("INICIAR 5");
    expect(html).toContain("INICIAR 10");
    expect(html).toContain("INICIAR 25");
    expect(html).toContain("DETENER Y LIMPIAR");
    expect(html).toContain("EXPORTAR JSON LOCAL");
    expect(html).toContain("Métricas locales observadas");
    expect(html).toContain("Pérdida QUIC y jitter QUIC:");
    expect(html).toContain("no medidos");
    expect(html).not.toContain("192.168.10.20");
    expect(html).not.toContain("aaaaaaaa");
    expect(readFileSync("src/components/lan-load-generator.tsx", "utf8"))
      .toContain('link.download = "local-browser-observation-user-exported.json"');
  });

  it("no crea canvas, decoder, Gateway, input ni endpoints mutables", () => {
    const component = readFileSync("src/components/lan-load-generator.tsx", "utf8");
    const generator = readFileSync("src/lib/lan-lab/load-generator.ts", "utf8");
    const route = readFileSync("src/app/lan-load/page.tsx", "utf8");
    const runtimeSurface = `${component}\n${generator}`;
    const surface = `${runtimeSurface}\n${route}`;
    expect(runtimeSurface).not.toContain("VideoDecoder");
    expect(surface).not.toContain("<canvas");
    expect(surface).not.toContain("/gateway/");
    expect(surface).not.toContain("/input/");
    expect(surface).not.toMatch(/\b(POST|PUT|PATCH|DELETE)\b/);
    expect(route).toContain("if (!isLanLabEnabled(process.env)) notFound()");
    expect(route).toContain("await connection()");
  });

  it("define foco visible y responsive móvil verificables", () => {
    const css = readFileSync("src/components/lan-load-generator.module.css", "utf8");
    expect(css).toContain(":focus-visible");
    expect(css).toContain("@media (max-width: 620px)");
    expect(css).toContain("grid-template-columns: 1fr");
  });
});
