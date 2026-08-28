import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { DemuxedVideoSample, VideoConfiguration } from "./cmaf-demuxer";
import { CanvasVideoDecoder, type DecoderEvent } from "./video-decoder";

type DecoderCallbacks = {
  output(frame: VideoFrame): void;
  error(error: DOMException): void;
};

class MockVideoDecoder {
  static instances: MockVideoDecoder[] = [];
  static support: Promise<VideoDecoderSupport> = Promise.resolve({
    supported: true,
    config: { codec: "avc1.42c01f" },
  });
  readonly callbacks: DecoderCallbacks;
  state: CodecState = "unconfigured";
  decodeQueueSize = 0;
  decoded: EncodedVideoChunk[] = [];

  static isConfigSupported() {
    return MockVideoDecoder.support;
  }

  constructor(callbacks: DecoderCallbacks) {
    this.callbacks = callbacks;
    MockVideoDecoder.instances.push(this);
  }

  configure() {
    this.state = "configured";
  }

  decode(chunk: EncodedVideoChunk) {
    this.decoded.push(chunk);
  }

  close() {
    this.state = "closed";
  }
}

class MockEncodedVideoChunk {
  readonly type: EncodedVideoChunkType;
  readonly timestamp: number;
  readonly duration: number | null;

  constructor(init: EncodedVideoChunkInit) {
    this.type = init.type;
    this.timestamp = init.timestamp;
    this.duration = init.duration ?? null;
  }
}

const configuration: VideoConfiguration = {
  codec: "avc1.42c01f",
  codedWidth: 640,
  codedHeight: 360,
  description: new ArrayBuffer(4),
};

function sample(key: boolean): DemuxedVideoSample {
  return {
    data: Uint8Array.of(1, 2, 3),
    timestampUs: key ? 0 : 33_333,
    durationUs: 33_333,
    key,
    receivedAtMs: 0,
  };
}

function frame(timestamp = 0) {
  return {
    timestamp,
    displayWidth: 640,
    displayHeight: 360,
    close: vi.fn(),
  } as unknown as VideoFrame;
}

function canvas() {
  const context = {
    drawImage: vi.fn(),
    getImageData: vi.fn(() => ({ data: new Uint8ClampedArray(4) })),
  };
  return {
    width: 640,
    height: 360,
    getContext: vi.fn(() => context),
  } as unknown as HTMLCanvasElement;
}

beforeEach(() => {
  MockVideoDecoder.instances = [];
  MockVideoDecoder.support = Promise.resolve({
    supported: true,
    config: { codec: "avc1.42c01f" },
  });
  vi.stubGlobal("VideoDecoder", MockVideoDecoder);
  vi.stubGlobal("EncodedVideoChunk", MockEncodedVideoChunk);
  vi.stubGlobal("document", { createElement: () => canvas() });
  vi.stubGlobal("window", {
    requestAnimationFrame: vi.fn(() => 1),
    cancelAnimationFrame: vi.fn(),
  });
});

afterEach(() => {
  vi.unstubAllGlobals();
});

describe("CanvasVideoDecoder lifecycle", () => {
  it("no crea decoder si el teardown ocurre durante configure", async () => {
    let resolveSupport: (support: VideoDecoderSupport) => void = () => undefined;
    MockVideoDecoder.support = new Promise((resolve) => { resolveSupport = resolve; });
    const events: DecoderEvent[] = [];
    const decoder = new CanvasVideoDecoder(canvas(), (event) => events.push(event));
    const configuring = decoder.configure(configuration);

    decoder.close();
    resolveSupport({ supported: true, config: { codec: "avc1.42c01f" } });
    await configuring;

    expect(MockVideoDecoder.instances).toHaveLength(0);
    expect(events).toEqual([]);
  });

  it("cierra frames tardíos de una generación anterior sin callback", async () => {
    const events: DecoderEvent[] = [];
    const decoder = new CanvasVideoDecoder(canvas(), (event) => events.push(event));
    await decoder.configure(configuration);
    const previous = MockVideoDecoder.instances[0];
    decoder.signalGap();
    const lateFrame = frame();

    previous.callbacks.output(lateFrame);

    expect(lateFrame.close).toHaveBeenCalledOnce();
    expect(events.filter((event) => event.type === "frame")).toEqual([]);
  });

  it("descarta delta con decoder saturado y conserva el keyframe", async () => {
    const events: DecoderEvent[] = [];
    const decoder = new CanvasVideoDecoder(canvas(), (event) => events.push(event));
    await decoder.configure(configuration);
    const saturated = MockVideoDecoder.instances[0];
    decoder.decode(sample(true));
    saturated.decodeQueueSize = 8;

    decoder.decode(sample(false));
    decoder.decode(sample(true));

    const current = MockVideoDecoder.instances.at(-1);
    expect(events).toContainEqual({ type: "dropped", reason: "decode-backpressure" });
    expect(saturated.state).toBe("closed");
    expect(current?.decoded).toHaveLength(1);
    expect(current?.decoded[0].type).toBe("key");
  });

  it("cierra frames pendientes y no emite eventos tras close", async () => {
    const events: DecoderEvent[] = [];
    const decoder = new CanvasVideoDecoder(canvas(), (event) => events.push(event));
    await decoder.configure(configuration);
    const pendingFrame = frame();
    MockVideoDecoder.instances[0].callbacks.output(pendingFrame);
    const eventCount = events.length;

    decoder.close();

    expect(pendingFrame.close).toHaveBeenCalledOnce();
    expect(events).toHaveLength(eventCount);
    expect(window.cancelAnimationFrame).toHaveBeenCalled();
  });
});
