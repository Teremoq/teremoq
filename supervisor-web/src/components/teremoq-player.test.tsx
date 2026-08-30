import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

describe("superficie del player LAN", () => {
  const component = readFileSync("src/components/teremoq-player.tsx", "utf8");
  const page = readFileSync("src/app/page.tsx", "utf8");

  it("conserva las ramas y etiquetas del supervisor loopback por defecto", () => {
    expect(component).toContain('loadPlaybackConfiguration(controller.signal)');
    expect(component).toContain('loadGatewaySnapshot(controller.signal)');
    expect(component).toContain('"LEYENDO GATEWAY…"');
    expect(page).toContain('"SUPERVISOR / SIGNAL COMPARISON"');
    expect(page).toContain('href="/operations"');
    expect(page).toContain("if (isLanLabEnabled(process.env)) return <LanLabHome />");
    expect(page.indexOf("await connection()"))
      .toBeGreaterThan(page.indexOf("async function LanLabHome()"));
  });

  it("muestra LAN no productivo sin dashboard, preview ni métricas inventadas", () => {
    expect(page).toContain('"TEREMOQ LAN LAB · NO PRODUCCIÓN"');
    expect(page).toContain("deployment.operationsAvailable");
    expect(component).toContain('"SALUD NO MEDIDA"');
    expect(component).toContain('"Preview de entrada no disponible en el paquete LAN"');
    expect(component).toContain("OBJ —");
    expect(component).toContain("policy.loadGatewayPlayback");
    expect(component).toContain("policy.pollGatewaySnapshot");
  });

  it("deshabilita la conexión si el opt-in LAN no tiene configuración válida", () => {
    expect(component).toContain('disabled={!compatible || !configurationAvailable}');
    expect(component).toContain("Configuración LAN local ausente o inválida");
  });
});
