import type { DemuxedVideoSample, VideoConfiguration } from "./cmaf-demuxer";
import { FramePacer } from "./frame-pacer";
import {
  decodeVisualTimecodeRow,
  visualTimecodeLatencyMs,
  visualTimecodeRegion,
} from "./visual-timecode";

// At 30 fps this admits at most ~267 ms of decoder work. It absorbs short
// QUIC/worker bursts without turning the browser into an unbounded playout
// buffer; the next delta is still discarded if the bounded budget is full.
const MAX_DECODE_QUEUE = 8;
const TIMECODE_SAMPLE_INTERVAL_FRAMES = 3;

export type DecoderEvent =
  | { type: "configured"; codec: string }
  | {
      type: "frame";
      timestampUs: number;
      rxToCanvasMs: number;
      sourceToRxMs: number | null;
      sourceToCanvasMs: number | null;
      sourceTimecodeMs: number | null;
      queue: number;
    }
  | {
      type: "dropped";
      reason: "waiting-key" | "decode-backpressure" | "stale-frame" | "presentation-backpressure";
    }
  | { type: "error"; message: string };

export class CanvasVideoDecoder {
  readonly #canvas: HTMLCanvasElement;
  readonly #context: CanvasRenderingContext2D;
  readonly #timecodeCanvas: HTMLCanvasElement;
  readonly #timecodeContext: CanvasRenderingContext2D;
  readonly #onEvent: (event: DecoderEvent) => void;
  #decoder: VideoDecoder | null = null;
  readonly #pacer: FramePacer<VideoFrame>;
  #configuration: VideoDecoderConfig | null = null;
  #waitingForKey = true;
  #lastRenderedTimestamp = -1;
  #receivedTimes = new Map<number, number>();
  #renderedFrames = 0;

  constructor(canvas: HTMLCanvasElement, onEvent: (event: DecoderEvent) => void) {
    this.#canvas = canvas;
    const context = canvas.getContext("2d", {
      alpha: false,
      desynchronized: true,
    });
    if (!context) throw new Error("contexto canvas 2D no disponible");
    const timecodeCanvas = document.createElement("canvas");
    const timecodeContext = timecodeCanvas.getContext("2d", {
      alpha: false,
      willReadFrequently: true,
    });
    if (!timecodeContext) throw new Error("contexto de telemetría visual no disponible");
    this.#context = context;
    this.#timecodeCanvas = timecodeCanvas;
    this.#timecodeContext = timecodeContext;
    this.#onEvent = onEvent;
    this.#pacer = new FramePacer(
      (frame) => this.#render(frame),
      (frame) => this.#discardDecodedFrame(frame),
    );
  }

  async configure(configuration: VideoConfiguration) {
    const config: VideoDecoderConfig = {
      codec: configuration.codec,
      codedWidth: configuration.codedWidth,
      codedHeight: configuration.codedHeight,
      description: configuration.description,
      hardwareAcceleration: "prefer-hardware",
      optimizeForLatency: true,
    };
    let support = await VideoDecoder.isConfigSupported(config);
    if (!support.supported) {
      const fallback = { ...config, hardwareAcceleration: "no-preference" as const };
      support = await VideoDecoder.isConfigSupported(fallback);
    }
    if (!support.supported) throw new Error(`WebCodecs no soporta ${configuration.codec}`);
    this.#configuration = support.config ?? config;
    this.#recreateDecoder();
    this.#onEvent({ type: "configured", codec: configuration.codec });
  }

  signalGap() {
    this.#pacer.clear();
    this.#waitingForKey = true;
    this.#lastRenderedTimestamp = -1;
    this.#receivedTimes.clear();
    this.#renderedFrames = 0;
    if (this.#decoder?.state === "configured" && this.#configuration) {
      this.#decoder.reset();
      this.#decoder.configure(this.#configuration);
    }
  }

  decode(sample: DemuxedVideoSample) {
    const decoder = this.#decoder;
    if (!decoder || decoder.state !== "configured") return;
    if (this.#waitingForKey && !sample.key) {
      this.#onEvent({ type: "dropped", reason: "waiting-key" });
      return;
    }
    if (decoder.decodeQueueSize >= MAX_DECODE_QUEUE && !sample.key) {
      this.#onEvent({ type: "dropped", reason: "decode-backpressure" });
      return;
    }
    if (sample.key) {
      if (decoder.decodeQueueSize >= MAX_DECODE_QUEUE) this.signalGap();
      this.#waitingForKey = false;
    }
    this.#receivedTimes.set(sample.timestampUs, sample.receivedAtMs);
    try {
      decoder.decode(
        new EncodedVideoChunk({
          type: sample.key ? "key" : "delta",
          timestamp: sample.timestampUs,
          duration: sample.durationUs,
          data: sample.data,
        }),
      );
    } catch (cause: unknown) {
      this.#receivedTimes.delete(sample.timestampUs);
      this.#recover(cause);
    }
  }

  close() {
    this.#pacer.clear();
    if (this.#decoder?.state !== "closed") this.#decoder?.close();
    this.#decoder = null;
    this.#receivedTimes.clear();
  }

  #recreateDecoder() {
    if (!this.#configuration) return;
    if (this.#decoder?.state !== "closed") this.#decoder?.close();
    this.#decoder = new VideoDecoder({
      output: (frame) => this.#pacer.push(frame),
      error: (error) => this.#recover(error),
    });
    this.#decoder.configure(this.#configuration);
    this.#waitingForKey = true;
  }

  #render(frame: VideoFrame) {
    try {
      if (frame.timestamp <= this.#lastRenderedTimestamp) {
        this.#onEvent({ type: "dropped", reason: "stale-frame" });
        return;
      }
      if (this.#canvas.width !== frame.displayWidth || this.#canvas.height !== frame.displayHeight) {
        this.#canvas.width = frame.displayWidth;
        this.#canvas.height = frame.displayHeight;
      }
      this.#context.drawImage(frame, 0, 0, this.#canvas.width, this.#canvas.height);
      this.#lastRenderedTimestamp = frame.timestamp;
      const sourceTimecodeMs =
        this.#renderedFrames % TIMECODE_SAMPLE_INTERVAL_FRAMES === 0
          ? this.#readTimecode(frame)
          : null;
      this.#renderedFrames += 1;
      const presentedAtEpochMs = performance.timeOrigin + performance.now();
      const receivedAt = this.#receivedTimes.get(frame.timestamp);
      const sourceToRxMs =
        sourceTimecodeMs === null || receivedAt === undefined
          ? null
          : visualTimecodeLatencyMs(
              sourceTimecodeMs,
              performance.timeOrigin + receivedAt,
            );
      this.#receivedTimes.delete(frame.timestamp);
      this.#onEvent({
        type: "frame",
        timestampUs: frame.timestamp,
        rxToCanvasMs: receivedAt === undefined ? 0 : performance.now() - receivedAt,
        sourceToRxMs,
        sourceToCanvasMs:
          sourceTimecodeMs === null
            ? null
            : visualTimecodeLatencyMs(sourceTimecodeMs, presentedAtEpochMs),
        sourceTimecodeMs,
        queue: this.#decoder?.decodeQueueSize ?? 0,
      });
    } catch (cause: unknown) {
      this.#recover(cause);
    } finally {
      frame.close();
    }
  }

  #recover(cause: unknown) {
    const message = cause instanceof Error ? cause.message : String(cause);
    this.#onEvent({ type: "error", message });
    this.#receivedTimes.clear();
    this.#pacer.clear();
    this.#recreateDecoder();
  }

  #discardDecodedFrame(frame: VideoFrame) {
    this.#receivedTimes.delete(frame.timestamp);
    this.#onEvent({ type: "dropped", reason: "presentation-backpressure" });
  }

  #readTimecode(frame: VideoFrame) {
    const region = visualTimecodeRegion(frame.displayWidth, frame.displayHeight);
    if (frame.displayWidth < region.x + region.width || frame.displayHeight <= region.y) return null;
    if (this.#timecodeCanvas.width !== region.width) this.#timecodeCanvas.width = region.width;
    if (this.#timecodeCanvas.height !== 1) this.#timecodeCanvas.height = 1;
    this.#timecodeContext.drawImage(
      frame,
      region.x,
      region.y,
      region.width,
      1,
      0,
      0,
      region.width,
      1,
    );
    return decodeVisualTimecodeRow(
      this.#timecodeContext.getImageData(0, 0, region.width, 1).data,
      region.stride,
    );
  }
}
