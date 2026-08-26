import { MoqSession, decodeSha256Hex, type SessionEvent } from "../moqt/session";
import type { MoqObject } from "../moqt/subgroup";
import {
  parseVideoCatalog,
  type CatalogVideoTrackName,
} from "./catalog";
import { CmafDemuxer, type DemuxedVideoSample } from "./cmaf-demuxer";
import { CanvasVideoDecoder, type DecoderEvent } from "./video-decoder";
import { LatencyWindow } from "./latency-window";
import { ObjectReorderBuffer } from "./object-reorder-buffer";
import { loadPlaybackConfiguration } from "../supervisor/api";
import { parseVehicleTelemetry, type VehicleTelemetry } from "./telemetry";

const UI_SNAPSHOT_INTERVAL_MS = 250;
const RECONNECT_BASE_DELAY_MS = 250;
const RECONNECT_MAX_DELAY_MS = 2_000;
const PRESENTATION_LATENCY_SAMPLES = 512;
const LATENCY_SNAPSHOT_INTERVAL_MS = 250;

export type PlayerPhase =
  | "idle"
  | "connecting"
  | "catalog"
  | "subscribing"
  | "receiving"
  | "playing"
  | "error"
  | "stopped";

export type PlayerSnapshot = {
  phase: PlayerPhase;
  message: string;
  relayUrl: string;
  codec: string;
  decoderQueue: number;
  frames: number;
  dropped: number;
  lastTimestampUs: number | null;
  rxToCanvasMs: number | null;
  rxToCanvasSamples: number;
  rxToCanvasP50Ms: number | null;
  rxToCanvasP95Ms: number | null;
  rxToCanvasP99Ms: number | null;
  sourceTimecodeMs: number | null;
  sourceToRxSamples: number;
  sourceToRxP50Ms: number | null;
  sourceToRxP95Ms: number | null;
  sourceToRxP99Ms: number | null;
  sourceToCanvasSamples: number;
  sourceToCanvasP50Ms: number | null;
  sourceToCanvasP95Ms: number | null;
  sourceToCanvasP99Ms: number | null;
  telemetry: VehicleTelemetry | null;
  telemetryObjects: number;
  telemetryRejected: number;
};

export type VideoTrackId = 0 | 1;

const INITIAL_SNAPSHOT: PlayerSnapshot = {
  phase: "idle",
  message: "Preparado para conectar",
  relayUrl: "https://127.0.0.1:14434/watch",
  codec: "—",
  decoderQueue: 0,
  frames: 0,
  dropped: 0,
  lastTimestampUs: null,
  rxToCanvasMs: null,
  rxToCanvasSamples: 0,
  rxToCanvasP50Ms: null,
  rxToCanvasP95Ms: null,
  rxToCanvasP99Ms: null,
  sourceTimecodeMs: null,
  sourceToRxSamples: 0,
  sourceToRxP50Ms: null,
  sourceToRxP95Ms: null,
  sourceToRxP99Ms: null,
  sourceToCanvasSamples: 0,
  sourceToCanvasP50Ms: null,
  sourceToCanvasP95Ms: null,
  sourceToCanvasP99Ms: null,
  telemetry: null,
  telemetryObjects: 0,
  telemetryRejected: 0,
};

export class TeremoqPlayerEngine {
  readonly #decoder: CanvasVideoDecoder;
  readonly #presentationLatency = new LatencyWindow(PRESENTATION_LATENCY_SAMPLES);
  readonly #sourceToRxLatency = new LatencyWindow(PRESENTATION_LATENCY_SAMPLES);
  readonly #sourceLatency = new LatencyWindow(PRESENTATION_LATENCY_SAMPLES);
  readonly #videoReorder = new ObjectReorderBuffer();
  readonly #onSnapshot: (snapshot: PlayerSnapshot) => void;
  readonly #trackId: VideoTrackId;
  readonly #trackName: CatalogVideoTrackName;
  #snapshot = { ...INITIAL_SNAPSHOT };
  #session: MoqSession | null = null;
  #demuxer: CmafDemuxer | null = null;
  #decoderReady: Promise<void> | null = null;
  #decoderFailed = false;
  #namespace: string[] = [];
  #videoSubscriptionStarted = false;
  #lastUiSnapshotAt = Number.NEGATIVE_INFINITY;
  #lastLatencySnapshotAt = Number.NEGATIVE_INFINITY;
  #generation = 0;
  #reconnectAttempt = 0;
  #reconnectTimer: number | null = null;
  #stopped = false;

  constructor(
    canvas: HTMLCanvasElement,
    onSnapshot: (snapshot: PlayerSnapshot) => void,
    trackId: VideoTrackId = 0,
  ) {
    this.#onSnapshot = onSnapshot;
    this.#trackId = trackId;
    this.#trackName = trackId === 0 ? "0-video-hq" : "1-video-lq";
    this.#decoder = new CanvasVideoDecoder(canvas, (event) => this.#handleDecoderEvent(event));
    this.#snapshot = { ...INITIAL_SNAPSHOT };
    this.#onSnapshot({ ...this.#snapshot });
  }

  async start() {
    this.#stopped = false;
    this.#reconnectAttempt = 0;
    this.#update({ phase: "connecting", message: "Leyendo configuración segura del Gateway" });
    try {
      await this.#connect();
    } catch (cause: unknown) {
      // A failed opening handshake is a transient network condition in an Edge
      // deployment, not a terminal player error. Keep the session live and let
      // the operator stop it explicitly if needed.
      this.#recoverConnection(cause, this.#generation);
    }
  }

  stop() {
    if (this.#stopped) return;
    this.#stopped = true;
    this.#generation += 1;
    if (this.#reconnectTimer !== null) window.clearTimeout(this.#reconnectTimer);
    this.#reconnectTimer = null;
    this.#session?.close(0, "player detenido");
    this.#session = null;
    this.#demuxer?.flush();
    this.#demuxer = null;
    this.#videoReorder.reset();
    this.#decoder.close();
    this.#update({ phase: "stopped", message: "Sesión detenida por el operador", decoderQueue: 0 });
  }

  async #connect() {
    const generation = ++this.#generation;
    const playback = await loadPlaybackConfiguration();
    if (this.#stopped || generation !== this.#generation) return;
    this.#namespace = playback.namespace;
    this.#update({ relayUrl: playback.relayUrl, message: "Abriendo WebTransport" });
    const fingerprint = await loadFingerprint();
    if (this.#stopped || generation !== this.#generation) return;
    const session = await MoqSession.connect(
      playback.relayUrl,
      fingerprint,
      (event) => this.#handleSessionEvent(event, generation),
    );
    if (this.#stopped || generation !== this.#generation) {
      session.close(0, "intento de conexión obsoleto");
      return;
    }
    this.#session = session;
    this.#reconnectAttempt = 0;
    this.#update({ phase: "catalog", message: "Solicitando catálogo MSF" });
    await Promise.all([
      session.subscribe(this.#namespace, "catalog", (object) =>
        this.#handleCatalog(object, generation),
      ),
      session.subscribe(this.#namespace, "3-telemetry", (object) =>
        this.#handleTelemetry(object, generation),
      ),
    ]);
  }

  async #handleCatalog(object: MoqObject, generation: number) {
    if (generation !== this.#generation || this.#videoSubscriptionStarted || this.#stopped) return;
    try {
      const track = parseVideoCatalog(object.payload, this.#trackName);
      if (track === null) {
        this.#update({
          phase: "catalog",
          message: `Catálogo recibido; esperando Track ${this.#trackId}`,
        });
        return;
      }
      this.#videoSubscriptionStarted = true;
      this.#update({ codec: track.codec, phase: "subscribing", message: "Inicializando CMAF y WebCodecs" });
      this.#demuxer = new CmafDemuxer({
        onConfiguration: (configuration) => {
          this.#decoderReady = this.#decoder.configure(configuration).catch((cause: unknown) => {
            this.#decoderFailed = true;
            this.#fatal(cause);
          });
        },
        onSample: (sample) => this.#handleSample(sample),
        onError: (error) => this.#fatal(error),
      });
      this.#demuxer.initialize(track.initialization);
      await this.#session?.subscribe(this.#namespace, track.name, (mediaObject) =>
        this.#handleVideoObject(mediaObject, generation),
      );
      if (generation === this.#generation) {
        this.#update({
          phase: "receiving",
          message: `Track ${this.#trackId} suscrito; esperando I-frame`,
        });
      }
    } catch (cause: unknown) {
      this.#fatal(cause);
    }
  }

  #handleVideoObject(object: MoqObject, generation: number) {
    if (generation !== this.#generation || this.#stopped || object.status !== null) return;
    const reordered = this.#videoReorder.push(object);
    if (reordered.dropped > 0) {
      this.#update({ dropped: this.#snapshot.dropped + reordered.dropped }, true);
    }
    if (reordered.resync) this.#decoder.signalGap();
    try {
      for (const ready of reordered.ready) {
        this.#demuxer?.appendFragment(ready.payload, performance.now());
      }
    } catch (cause: unknown) {
      this.#videoReorder.reset();
      this.#decoder.signalGap();
      this.#fatal(cause);
    }
  }

  #handleTelemetry(object: MoqObject, generation: number) {
    if (generation !== this.#generation || this.#stopped || object.status !== null) return;
    try {
      const telemetry = parseVehicleTelemetry(object.payload);
      this.#update(
        {
          telemetry,
          telemetryObjects: this.#snapshot.telemetryObjects + 1,
        },
        true,
      );
    } catch {
      this.#update(
        { telemetryRejected: this.#snapshot.telemetryRejected + 1 },
        true,
      );
    }
  }

  #handleSample(sample: DemuxedVideoSample) {
    const ready = this.#decoderReady;
    if (!ready) {
      this.#update({ dropped: this.#snapshot.dropped + 1 }, true);
      return;
    }
    void ready.then(() => {
      if (!this.#stopped && !this.#decoderFailed) this.#decoder.decode(sample);
    });
  }

  #handleSessionEvent(event: SessionEvent, generation: number) {
    if (generation !== this.#generation || this.#stopped) return;
    if (event.type === "stream-dropped") {
      this.#decoder.signalGap();
      this.#update({
        dropped: this.#snapshot.dropped + 1,
        message: `Stream descartado: ${event.reason}`,
      });
    } else if (event.type === "error") {
      this.#recoverConnection(new Error(event.message), generation);
    }
  }

  #recoverConnection(cause: unknown, generation: number) {
    if (this.#stopped || generation !== this.#generation || this.#reconnectTimer !== null) return;
    this.#generation += 1;
    this.#session?.close(0x03, "reconexión automática");
    this.#session = null;
    this.#demuxer?.flush();
    this.#demuxer = null;
    this.#videoReorder.reset();
    this.#decoder.signalGap();
    this.#presentationLatency.clear();
    this.#sourceToRxLatency.clear();
    this.#sourceLatency.clear();
    this.#decoderReady = null;
    this.#decoderFailed = false;
    this.#videoSubscriptionStarted = false;
    const message = cause instanceof Error ? cause.message : String(cause);
    const delay = Math.min(
      RECONNECT_MAX_DELAY_MS,
      RECONNECT_BASE_DELAY_MS * 2 ** this.#reconnectAttempt,
    );
    this.#reconnectAttempt += 1;
    this.#update({
      phase: "connecting",
      message: `Conexión perdida; reintentando en ${delay} ms (${message})`,
      decoderQueue: 0,
      rxToCanvasMs: null,
      rxToCanvasSamples: 0,
      rxToCanvasP50Ms: null,
      rxToCanvasP95Ms: null,
      rxToCanvasP99Ms: null,
      sourceTimecodeMs: null,
      sourceToRxSamples: 0,
      sourceToRxP50Ms: null,
      sourceToRxP95Ms: null,
      sourceToRxP99Ms: null,
      sourceToCanvasSamples: 0,
      sourceToCanvasP50Ms: null,
      sourceToCanvasP95Ms: null,
      sourceToCanvasP99Ms: null,
      telemetry: null,
      telemetryObjects: 0,
      telemetryRejected: 0,
    });
    this.#reconnectTimer = window.setTimeout(() => {
      this.#reconnectTimer = null;
      if (this.#stopped) return;
      void this.#connect().catch((retryCause: unknown) => {
        this.#recoverConnection(retryCause, this.#generation);
      });
    }, delay);
  }

  #handleDecoderEvent(event: DecoderEvent) {
    if (event.type === "configured") {
      this.#update({ codec: event.codec, message: "Decoder configurado; esperando I-frame" });
    } else if (event.type === "frame") {
      this.#presentationLatency.record(event.rxToCanvasMs);
      if (event.sourceToCanvasMs !== null) {
        this.#sourceLatency.record(event.sourceToCanvasMs);
      }
      if (event.sourceToRxMs !== null) {
        this.#sourceToRxLatency.record(event.sourceToRxMs);
      }
      const patch: Partial<PlayerSnapshot> = {
        phase: "playing",
        message: `Track ${this.#trackId} en reproducción`,
        frames: this.#snapshot.frames + 1,
        decoderQueue: event.queue,
        lastTimestampUs: event.timestampUs,
        rxToCanvasMs: event.rxToCanvasMs,
      };
      if (event.sourceTimecodeMs !== null) patch.sourceTimecodeMs = event.sourceTimecodeMs;
      const now = performance.now();
      if (now - this.#lastLatencySnapshotAt >= LATENCY_SNAPSHOT_INTERVAL_MS) {
        this.#lastLatencySnapshotAt = now;
        const latency = this.#presentationLatency.snapshot();
        const sourceToRxLatency = this.#sourceToRxLatency.snapshot();
        const sourceLatency = this.#sourceLatency.snapshot();
        Object.assign(patch, {
          rxToCanvasSamples: latency.samples,
          rxToCanvasP50Ms: latency.p50Ms,
          rxToCanvasP95Ms: latency.p95Ms,
          rxToCanvasP99Ms: latency.p99Ms,
          sourceToRxSamples: sourceToRxLatency.samples,
          sourceToRxP50Ms: sourceToRxLatency.p50Ms,
          sourceToRxP95Ms: sourceToRxLatency.p95Ms,
          sourceToRxP99Ms: sourceToRxLatency.p99Ms,
          sourceToCanvasSamples: sourceLatency.samples,
          sourceToCanvasP50Ms: sourceLatency.p50Ms,
          sourceToCanvasP95Ms: sourceLatency.p95Ms,
          sourceToCanvasP99Ms: sourceLatency.p99Ms,
        });
      }
      this.#update(patch, true);
    } else if (event.type === "dropped") {
      this.#update({ dropped: this.#snapshot.dropped + 1 }, true);
    } else {
      this.#update({ message: `Decoder recuperándose: ${event.message}` });
    }
  }

  #fatal(cause: unknown) {
    if (this.#snapshot.phase === "error") return;
    const message = cause instanceof Error ? cause.message : String(cause);
    this.#stopped = true;
    this.#generation += 1;
    if (this.#reconnectTimer !== null) window.clearTimeout(this.#reconnectTimer);
    this.#reconnectTimer = null;
    this.#session?.close(0x03, message.slice(0, 128));
    this.#session = null;
    this.#decoder.close();
    this.#update({ phase: "error", message });
  }

  #update(patch: Partial<PlayerSnapshot>, throttleUi = false) {
    this.#snapshot = { ...this.#snapshot, ...patch };
    const now = performance.now();
    if (throttleUi && now - this.#lastUiSnapshotAt < UI_SNAPSHOT_INTERVAL_MS) return;
    this.#lastUiSnapshotAt = now;
    this.#onSnapshot({ ...this.#snapshot });
  }
}

export function initialPlayerSnapshot() {
  return { ...INITIAL_SNAPSHOT };
}

async function loadFingerprint() {
  const response = await fetch("/gateway/api/v1/moq-certificate.sha256", { cache: "no-store" });
  if (!response.ok) throw new Error(`fingerprint del relay no disponible (${response.status})`);
  return decodeSha256Hex(await response.text());
}
