import {
  MoqSession,
  WebTransportTrustError,
  decodeSha256Hex,
  type SessionEvent,
} from "../moqt/session";
import type { MoqObject } from "../moqt/subgroup";
import {
  parseVideoCatalog,
  type CatalogVideoTrackName,
} from "./catalog";
import { CmafDemuxer, type DemuxedVideoSample } from "./cmaf-demuxer";
import { CanvasVideoDecoder, type DecoderEvent } from "./video-decoder";
import { LatencyWindow } from "./latency-window";
import { ObjectReorderBuffer } from "./object-reorder-buffer";
import {
  PlaybackConfigurationError,
  loadPlaybackConfiguration,
} from "../supervisor/api";
import { parseVehicleTelemetry, type VehicleTelemetry } from "./telemetry";
import { BoundedReconnect } from "./reconnect";
import { AsyncByteReader, MoqProtocolError } from "../moqt/binary";
import { ActivityWatchdog } from "./activity-watchdog";

const UI_SNAPSHOT_INTERVAL_MS = 250;
const PRESENTATION_LATENCY_SAMPLES = 512;
const LATENCY_SNAPSHOT_INTERVAL_MS = 250;

export type PlayerPhase =
  | "waiting"
  | "connecting"
  | "active"
  | "degraded"
  | "stale"
  | "unavailable"
  | "closed";

export type PlayerReason =
  | "operator-waiting"
  | "connecting"
  | "media-waiting"
  | "healthy"
  | "video-pressure"
  | "video-stale"
  | "peer-silent"
  | "network-unreachable"
  | "retry-exhausted"
  | "configuration-invalid"
  | "trust-invalid"
  | "protocol-incompatible"
  | "decoder-unavailable"
  | "media-invalid"
  | "browser-unsupported"
  | "operator-closed";

type FailClosedReason = Extract<
  PlayerReason,
  | "retry-exhausted"
  | "configuration-invalid"
  | "trust-invalid"
  | "protocol-incompatible"
  | "decoder-unavailable"
  | "media-invalid"
>;

export type PlayerSnapshot = {
  phase: PlayerPhase;
  reason: PlayerReason;
  running: boolean;
  message: string;
  relayLabel: string;
  reconnectAttempt: number;
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
  phase: "waiting",
  reason: "operator-waiting",
  running: false,
  message: "Esperando inicio del operador",
  relayLabel: "Relay local del Gateway",
  reconnectAttempt: 0,
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
  readonly #reconnect = new BoundedReconnect();
  readonly #watchdog: ActivityWatchdog;
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
  #generationController: AbortController | null = null;
  #stopped = true;

  constructor(
    canvas: HTMLCanvasElement,
    onSnapshot: (snapshot: PlayerSnapshot) => void,
    trackId: VideoTrackId = 0,
  ) {
    this.#onSnapshot = onSnapshot;
    this.#trackId = trackId;
    this.#trackName = trackId === 0 ? "0-video-hq" : "1-video-lq";
    this.#decoder = new CanvasVideoDecoder(canvas, (event) => this.#handleDecoderEvent(event));
    this.#watchdog = new ActivityWatchdog({
      onVideoStale: () => {
        if (this.#stopped) return;
        this.#update({
          phase: "stale",
          reason: "video-stale",
          message: "Vídeo sin actividad reciente; telemetría permanece aislada",
        });
      },
      onPeerSilent: () => this.#recoverConnection(new PeerSilentError(), this.#generation),
    });
    this.#snapshot = { ...INITIAL_SNAPSHOT };
    this.#onSnapshot({ ...this.#snapshot });
  }

  async start() {
    if (!this.#stopped) return;
    this.#stopped = false;
    this.#reconnect.markHealthy();
    this.#update({
      phase: "connecting",
      reason: "connecting",
      running: true,
      message: "Validando configuración local",
      reconnectAttempt: 0,
    });
    try {
      await this.#connect();
    } catch (cause: unknown) {
      // Failure classification decides between a bounded network retry and a
      // visible fail-closed trust/configuration/protocol state.
      this.#recoverConnection(cause, this.#generation);
    }
  }

  stop() {
    if (this.#stopped) return;
    this.#stopped = true;
    this.#reconnect.cancel();
    this.#disposeGeneration("player detenido");
    this.#decoder.close();
    this.#update({
      phase: "closed",
      reason: "operator-closed",
      running: false,
      message: "Sesión cerrada por el operador",
      decoderQueue: 0,
    });
  }

  async #connect() {
    this.#generationController?.abort();
    const generation = ++this.#generation;
    const controller = new AbortController();
    this.#generationController = controller;
    const playback = await loadPlaybackConfiguration(controller.signal);
    if (this.#stopped || generation !== this.#generation) return;
    this.#namespace = playback.namespace;
    this.#update({ message: "Abriendo transporte autenticado" });
    const fingerprint = await loadFingerprint(controller.signal);
    if (this.#stopped || generation !== this.#generation) return;
    const session = await MoqSession.connect(
      playback.relayUrl,
      fingerprint,
      (event) => this.#handleSessionEvent(event, generation),
      controller.signal,
    );
    if (this.#stopped || generation !== this.#generation) {
      void session.close(0, "intento de conexión obsoleto");
      return;
    }
    this.#session = session;
    this.#update({
      phase: "waiting",
      reason: "media-waiting",
      message: "Esperando catálogo y primer keyframe",
    });
    this.#markActivity(generation, true);
    await Promise.all([
      session.subscribe(
        this.#namespace,
        "catalog",
        (object) => this.#handleCatalog(object, generation),
        "control",
      ),
      session.subscribe(
        this.#namespace,
        "3-telemetry",
        (object) => this.#handleTelemetry(object, generation),
        "critical",
      ),
    ]);
  }

  async #handleCatalog(object: MoqObject, generation: number) {
    if (
      generation !== this.#generation ||
      this.#videoSubscriptionStarted ||
      this.#stopped ||
      object.status !== null
    ) return;
    this.#markActivity(generation, false);
    try {
      const track = parseVideoCatalog(object.payload, this.#trackName);
      if (track === null) {
        this.#update({
          phase: "waiting",
          reason: "media-waiting",
          message: `Esperando Track ${this.#trackId}`,
        });
        return;
      }
      this.#videoSubscriptionStarted = true;
      this.#update({
        codec: track.codec,
        phase: "waiting",
        reason: "media-waiting",
        message: "Inicializando CMAF y WebCodecs",
      });
      this.#demuxer = new CmafDemuxer({
        onConfiguration: (configuration) => {
          if (generation !== this.#generation || this.#stopped) return;
          this.#decoderReady = this.#decoder.configure(configuration).catch(() => {
            if (generation !== this.#generation || this.#stopped) return;
            this.#decoderFailed = true;
            this.#failClosed("decoder-unavailable", "WebCodecs no admite esta señal");
          });
        },
        onSample: (sample) => this.#handleSample(sample, generation),
        onError: () => {
          if (generation === this.#generation && !this.#stopped) {
            this.#failClosed("media-invalid", "Media recibida fuera del contrato");
          }
        },
      });
      this.#demuxer.initialize(track.initialization);
      await this.#session?.subscribe(
        this.#namespace,
        track.name,
        (mediaObject) => this.#handleVideoObject(mediaObject, generation),
        "video",
      );
      if (generation === this.#generation) {
        this.#update({
          phase: "waiting",
          reason: "media-waiting",
          message: `Track ${this.#trackId} suscrito; esperando I-frame`,
        });
      }
    } catch (cause: unknown) {
      this.#recoverConnection(cause, generation);
    }
  }

  #handleVideoObject(object: MoqObject, generation: number) {
    if (generation !== this.#generation || this.#stopped || object.status !== null) return;
    this.#markActivity(generation, true);
    const reordered = this.#videoReorder.push(object);
    if (reordered.dropped > 0) {
      this.#update({ dropped: this.#snapshot.dropped + reordered.dropped }, true);
    }
    if (reordered.resync) this.#decoder.signalGap();
    try {
      for (const ready of reordered.ready) {
        this.#demuxer?.appendFragment(ready.payload, performance.now());
      }
    } catch {
      this.#videoReorder.reset();
      this.#decoder.signalGap();
      this.#failClosed("media-invalid", "Media recibida fuera del contrato");
    }
  }

  #handleTelemetry(object: MoqObject, generation: number) {
    if (generation !== this.#generation || this.#stopped || object.status !== null) return;
    this.#markActivity(generation, false);
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

  #handleSample(sample: DemuxedVideoSample, generation: number) {
    if (generation !== this.#generation || this.#stopped) return;
    const ready = this.#decoderReady;
    if (!ready) {
      this.#update({ dropped: this.#snapshot.dropped + 1 }, true);
      return;
    }
    void ready.then(() => {
      if (
        generation === this.#generation &&
        !this.#stopped &&
        !this.#decoderFailed
      ) this.#decoder.decode(sample);
    });
  }

  #handleSessionEvent(event: SessionEvent, generation: number) {
    if (generation !== this.#generation || this.#stopped) return;
    if (event.type === "connected") {
      this.#markActivity(generation, true);
    } else if (event.type === "stream-dropped") {
      this.#decoder.signalGap();
      this.#update({
        phase: "degraded",
        reason: "video-pressure",
        dropped: this.#snapshot.dropped + 1,
        message: "Vídeo resincronizando en el siguiente keyframe",
      });
    } else if (event.type === "error") {
      this.#recoverConnection(event.error, generation);
    }
  }

  #recoverConnection(cause: unknown, generation: number) {
    if (this.#stopped || generation !== this.#generation || isAbortError(cause)) return;
    const failure = classifyFailure(cause);
    if (failure.failClosed) {
      this.#failClosed(failure.reason, failure.message);
      return;
    }
    this.#disposeGeneration("reconexión automática");
    this.#presentationLatency.clear();
    this.#sourceToRxLatency.clear();
    this.#sourceLatency.clear();
    this.#decoderReady = null;
    this.#decoderFailed = false;
    this.#videoSubscriptionStarted = false;
    const waitingGeneration = this.#generation;
    const decision = this.#reconnect.schedule((attempt) => {
      if (this.#stopped || waitingGeneration !== this.#generation) return;
      this.#update({ reconnectAttempt: attempt });
      void this.#connect().catch((retryCause: unknown) => {
        this.#recoverConnection(retryCause, this.#generation);
      });
    });
    if (decision.status === "exhausted") {
      this.#failClosed("retry-exhausted", "Presupuesto de reconexión agotado");
      return;
    }
    this.#update({
      phase: "connecting",
      reason: failure.reason,
      message: `Red degradada; reintento ${decision.attempt} programado`,
      reconnectAttempt: decision.attempt,
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
  }

  #handleDecoderEvent(event: DecoderEvent) {
    if (this.#stopped) return;
    if (event.type === "configured") {
      this.#update({ codec: event.codec, message: "Decoder configurado; esperando I-frame" });
    } else if (event.type === "frame") {
      this.#reconnect.markHealthy();
      this.#markActivity(this.#generation, true);
      this.#presentationLatency.record(event.rxToCanvasMs);
      if (event.sourceToCanvasMs !== null) {
        this.#sourceLatency.record(event.sourceToCanvasMs);
      }
      if (event.sourceToRxMs !== null) {
        this.#sourceToRxLatency.record(event.sourceToRxMs);
      }
      const patch: Partial<PlayerSnapshot> = {
        phase: "active",
        reason: "healthy",
        message: `Track ${this.#trackId} en reproducción`,
        reconnectAttempt: 0,
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
      this.#update({
        phase: "degraded",
        reason: "video-pressure",
        message: "Presión de vídeo; descartando delta hasta recuperar",
        dropped: this.#snapshot.dropped + 1,
      }, true);
    } else {
      this.#update({
        phase: "degraded",
        reason: "video-pressure",
        message: "Decoder resincronizando en el siguiente keyframe",
      });
    }
  }

  #failClosed(
    reason: FailClosedReason,
    message: string,
  ) {
    if (this.#stopped && this.#snapshot.phase === "unavailable") return;
    this.#stopped = true;
    this.#reconnect.cancel();
    this.#disposeGeneration("cierre seguro");
    this.#decoder.close();
    this.#update({ phase: "unavailable", reason, running: false, message, decoderQueue: 0 });
  }

  #markActivity(generation: number, video: boolean) {
    if (generation !== this.#generation || this.#stopped) return;
    if (video) this.#watchdog.markVideoActivity();
    else this.#watchdog.markSessionActivity();
  }

  #disposeGeneration(reason: string) {
    this.#generation += 1;
    this.#generationController?.abort();
    this.#generationController = null;
    this.#watchdog.cancel();
    void this.#session?.close(0x03, reason);
    this.#session = null;
    this.#demuxer?.close();
    this.#demuxer = null;
    this.#videoReorder.reset();
    this.#decoder.suspend();
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

class TrustConfigurationError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "TrustConfigurationError";
  }
}

class PeerSilentError extends Error {
  constructor() {
    super("peer silencioso");
    this.name = "PeerSilentError";
  }
}

async function loadFingerprint(signal: AbortSignal) {
  const response = await fetch("/gateway/api/v1/moq-certificate.sha256", {
    cache: "no-store",
    signal,
  });
  if (!response.ok) throw new TrustConfigurationError("fingerprint no disponible");
  const declaredLength = Number(response.headers.get("content-length") ?? 0);
  if (declaredLength > 128) {
    throw new TrustConfigurationError("fingerprint fuera de límite");
  }
  try {
    if (!response.body) throw new TrustConfigurationError("fingerprint sin cuerpo");
    const bytes = await new AsyncByteReader(response.body, 128, signal).readAll(128);
    return decodeSha256Hex(new TextDecoder("utf-8", { fatal: true }).decode(bytes));
  } catch (cause: unknown) {
    throw new TrustConfigurationError(
      cause instanceof Error ? cause.message : "fingerprint inválido",
    );
  }
}

function classifyFailure(cause: unknown):
  | { failClosed: true; reason: FailClosedReason; message: string }
  | { failClosed: false; reason: "peer-silent" | "network-unreachable"; message: string } {
  if (cause instanceof PlaybackConfigurationError) {
    return {
      failClosed: true,
      reason: "configuration-invalid",
      message: "Configuración local inválida",
    };
  }
  if (cause instanceof TrustConfigurationError || cause instanceof WebTransportTrustError) {
    return {
      failClosed: true,
      reason: "trust-invalid",
      message: "Identidad del relay no válida",
    };
  }
  if (cause instanceof MoqProtocolError) {
    return {
      failClosed: true,
      reason: "protocol-incompatible",
      message: "Peer incompatible con MoQT draft-16",
    };
  }
  if (cause instanceof PeerSilentError) {
    return {
      failClosed: false,
      reason: "peer-silent",
      message: "Peer sin actividad",
    };
  }
  return {
    failClosed: false,
    reason: "network-unreachable",
    message: "Red no disponible",
  };
}

function isAbortError(cause: unknown) {
  return cause instanceof Error && cause.name === "AbortError";
}
