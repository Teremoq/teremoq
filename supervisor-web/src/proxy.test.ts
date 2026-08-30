import { NextRequest } from "next/server";
import { afterEach, describe, expect, it } from "vitest";
import { proxy } from "./proxy";

const previousLanMode = process.env.TEREMOQ_LAN_LAB;

afterEach(() => {
  if (previousLanMode === undefined) delete process.env.TEREMOQ_LAN_LAB;
  else process.env.TEREMOQ_LAN_LAB = previousLanMode;
});

describe("frontera HTTP del paquete LAN", () => {
  it("no cambia el routing normal cuando LAN no está habilitado", () => {
    delete process.env.TEREMOQ_LAN_LAB;
    expect(proxy(request("http://192.168.1.50/operations")).status).toBe(200);
  });

  it.each([
    "/gateway/api/v1/snapshot",
    "/gateway/api/v1/playback",
    "/gateway/api/v1/moq-certificate.sha256",
    "/operations",
    "/operations/api/control-plane",
    "/input/",
    "//operations",
  ])("oculta %s en LAN", (pathname) => {
    process.env.TEREMOQ_LAN_LAB = "1";
    const response = proxy(request(`http://127.0.0.1:3000${pathname}`));
    expect(response.status).toBe(404);
    expect(response.headers.get("cache-control")).toBe("no-store");
    expect(response.headers.get("content-security-policy")).toContain("default-src 'none'");
  });

  it("sólo admite la UI desde Host loopback y métodos de lectura", () => {
    process.env.TEREMOQ_LAN_LAB = "1";
    expect(proxy(request("http://127.0.0.1:3000/")).status).toBe(200);
    expect(proxy(request("http://localhost:3000/")).status).toBe(200);
    expect(proxy(request("http://localhost:3000/lan-load")).status).toBe(200);
    expect(proxy(request("http://localhost:3000/_next/static/app.js")).status).toBe(200);
    expect(proxy(request("http://localhost:3000/desconocido")).status).toBe(404);
    expect(proxy(request("http://192.168.1.50:3000/")).status).toBe(421);
    expect(proxy(request("http://127.0.0.1:3000/", "POST")).status).toBe(405);
    expect(proxy(request("http://127.0.0.1:3000/lan-load", "DELETE")).status).toBe(405);
  });
});

function request(url: string, method = "GET") {
  return new NextRequest(url, {
    method,
    headers: { host: new URL(url).host },
  });
}
