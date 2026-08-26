import { describe, expect, it } from "vitest";
import { AsyncByteReader, ByteCursor, ByteWriter, MoqProtocolError } from "./binary";
import {
  encodeClientSetup,
  encodeSubscribe,
  parseControlMessage,
} from "./control";
import { decodeSha256Hex } from "./session";
import { parseSubgroupStream, readSubgroupStream } from "./subgroup";
import { parseVideoCatalog } from "../player/catalog";

describe("QUIC varint draft-16", () => {
  it.each([0, 63, 64, 16_383, 16_384, 2 ** 30 - 1, 2 ** 30])(
    "round-trip %s",
    (value) => {
      const writer = new ByteWriter();
      writer.writeVarInt(value);
      const cursor = new ByteCursor(writer.toUint8Array());
      expect(cursor.readVarInt()).toBe(value);
      expect(cursor.remaining).toBe(0);
    },
  );

  it("rechaza payload truncado", () => {
    expect(() => new ByteCursor(Uint8Array.of(0x40)).readVarInt()).toThrow(
      MoqProtocolError,
    );
  });

  it("conserva el excedente cuando un chunk contiene varios campos", async () => {
    const reader = new AsyncByteReader(
      new ReadableStream<Uint8Array>({
        start(controller) {
          controller.enqueue(Uint8Array.of(1, 2, 3, 4));
          controller.close();
        },
      }),
      16,
    );
    expect(await reader.readVarInt()).toBe(1);
    expect([...await reader.readExact(3)]).toEqual([2, 3, 4]);
  });
});

describe("control MoQT draft-16", () => {
  it("codifica CLIENT_SETUP como el fixture de moq-rs bf87128", () => {
    expect([...encodeClientSetup(100)]).toEqual([0x20, 0, 4, 1, 2, 0x40, 0x64]);
  });

  it("decodifica SERVER_SETUP y SUBSCRIBE_OK", () => {
    expect(parseControlMessage(0x21, Uint8Array.of(1, 2, 0x43, 0xe8))).toEqual({
      type: "server-setup",
      maxRequestId: 1000,
    });
    expect(parseControlMessage(0x04, Uint8Array.of(0, 7, 0))).toEqual({
      type: "subscribe-ok",
      requestId: 0,
      trackAlias: 7,
    });
  });

  it("codifica SUBSCRIBE con namespace por campos y parámetros vacíos", () => {
    expect([...encodeSubscribe(0, ["teremoq", "live"], "catalog")]).toEqual([
      3, 0, 24, 0, 2, 7, 116, 101, 114, 101, 109, 111, 113, 4, 108, 105,
      118, 101, 7, 99, 97, 116, 97, 108, 111, 103, 0,
    ]);
  });
});

describe("Subgroup stream", () => {
  it("extrae un Object del formato SubgroupIdExt emitido por moq-rs", () => {
    const [object] = parseSubgroupStream(
      Uint8Array.of(0x15, 7, 2, 9, 1, 0, 0, 3, 97, 98, 99),
    );
    expect(object).toMatchObject({
      trackAlias: 7,
      groupId: 2,
      subgroupId: 9,
      publisherPriority: 1,
      objectIdDelta: 0,
      status: null,
    });
    expect(new TextDecoder().decode(object.payload)).toBe("abc");
  });

  it("rechaza Objects que superan el límite", () => {
    const oversizedLength = new ByteWriter();
    oversizedLength.writeVarInt(4 * 1024 * 1024 + 1);
    expect(() =>
      parseSubgroupStream(
        Uint8Array.from([0x15, 7, 2, 9, 2, 0, 0, ...oversizedLength.toUint8Array()]),
      ),
    ).toThrow(/Object supera/);
  });

  it("entrega cada Object sin esperar al cierre del Subgroup", async () => {
    const controlled = controllableStream();
    const stream = controlled.stream;
    const objects = readSubgroupStream(stream)[Symbol.asyncIterator]();

    controlled.controller().enqueue(Uint8Array.of(0x15, 7, 2, 9, 1, 0, 0, 3, 97, 98, 99));
    await expect(objects.next()).resolves.toMatchObject({
      done: false,
      value: {
        trackAlias: 7,
        groupId: 2,
        subgroupId: 9,
        objectIdDelta: 0,
        payload: Uint8Array.of(97, 98, 99),
      },
    });

    controlled.controller().enqueue(Uint8Array.of(1, 0, 2, 100, 101));
    await expect(objects.next()).resolves.toMatchObject({
      done: false,
      value: {
        objectIdDelta: 1,
        payload: Uint8Array.of(100, 101),
      },
    });
    controlled.controller().close();
    await expect(objects.next()).resolves.toEqual({ done: true, value: undefined });
  });
});

function controllableStream() {
  let source: ReadableStreamDefaultController<Uint8Array> | null = null;
  const stream = new ReadableStream<Uint8Array>({
    start(controller) {
      source = controller;
    },
  });
  return {
    stream,
    controller() {
      if (!source) throw new Error("controlador de test no inicializado");
      return source;
    },
  };
}

describe("fingerprint", () => {
  it("acepta exactamente 32 bytes SHA-256", () => {
    expect(decodeSha256Hex("ab".repeat(32))).toHaveLength(32);
    expect(() => decodeSha256Hex("ab")).toThrow(/fingerprint/);
  });
});

describe("catálogo MSF", () => {
  it("selecciona Track 0 y decodifica initData", () => {
    const payload = new TextEncoder().encode(
      JSON.stringify({
        version: 1,
        tracks: [
          {
            name: "0-video-hq",
            packaging: "cmaf",
            role: "video",
            codec: "avc1.42c01f",
            width: 1280,
            height: 720,
            initData: "AAECAw==",
          },
        ],
      }),
    );
    expect(parseVideoCatalog(payload)).toMatchObject({
      name: "0-video-hq",
      codec: "avc1.42c01f",
      width: 1280,
      height: 720,
      initialization: Uint8Array.of(0, 1, 2, 3),
    });
  });

  it("selecciona Track 1 cuando el catálogo contiene HQ y LQ", () => {
    const payload = new TextEncoder().encode(
      JSON.stringify({
        version: 1,
        tracks: [
          {
            name: "0-video-hq",
            packaging: "cmaf",
            role: "video",
            codec: "avc1.42c01f",
            width: 1280,
            height: 720,
            initData: "AAECAw==",
          },
          {
            name: "1-video-lq",
            packaging: "cmaf",
            role: "video",
            codec: "avc1.42c00d",
            width: 640,
            height: 360,
            initData: "BAUGBw==",
          },
        ],
      }),
    );
    expect(parseVideoCatalog(payload, "1-video-lq")).toMatchObject({
      name: "1-video-lq",
      codec: "avc1.42c00d",
      width: 640,
      height: 360,
      initialization: Uint8Array.of(4, 5, 6, 7),
    });
  });

  it("rechaza catálogos que no sean AVC/CMAF", () => {
    const payload = new TextEncoder().encode(JSON.stringify({ version: 1, tracks: [] }));
    expect(parseVideoCatalog(payload)).toBeNull();
  });
});
