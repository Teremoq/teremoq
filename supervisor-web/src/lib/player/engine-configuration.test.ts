import { afterEach, describe, expect, it, vi } from "vitest";
import { resolvePlayerDeployment } from "../lan-lab/config";
import { PlaybackConfigurationError } from "../supervisor/api";
import { resolvePlayerConnection } from "./engine";

const fingerprint = "ab".repeat(32);

afterEach(() => {
  vi.unstubAllGlobals();
});

describe("bootstrap del player LAN", () => {
  it("usa sólo configuración local validada y no contacta APIs remotas", async () => {
    const fetchMock = vi.fn(() => {
      throw new Error("fetch no permitido en LAN");
    });
    vi.stubGlobal("fetch", fetchMock);
    const deployment = resolvePlayerDeployment({
      TEREMOQ_LAN_LAB: "1",
      TEREMOQ_LAN_LAB_CONFIG: JSON.stringify({
        schema_version: 1,
        relay_url: "https://192.168.10.20:14433/watch",
        fingerprint_sha256: fingerprint,
        prefix_length: 24,
        namespace: "teremoq/site-7/live",
        run_id: "lan-engine-test",
        source_commit: "1".repeat(40),
      }),
    });

    const connection = await resolvePlayerConnection(
      deployment,
      new AbortController().signal,
    );

    expect(fetchMock).not.toHaveBeenCalled();
    expect(connection.relayUrl).toBe("https://192.168.10.20:14433/watch");
    expect(connection.namespace).toEqual(["teremoq", "site-7", "live"]);
    expect(connection.fingerprint).toEqual(new Uint8Array(32).fill(0xab));
  });

  it("falla cerrado sin configuración y observa cancelación antes de conectar", async () => {
    const deployment = resolvePlayerDeployment({ TEREMOQ_LAN_LAB: "1" });
    await expect(
      resolvePlayerConnection(deployment, new AbortController().signal),
    ).rejects.toBeInstanceOf(PlaybackConfigurationError);

    const controller = new AbortController();
    controller.abort();
    await expect(resolvePlayerConnection(deployment, controller.signal)).rejects.toMatchObject({
      name: "AbortError",
    });
  });
});
