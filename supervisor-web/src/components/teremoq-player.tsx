"use client";

import { useEffect, useRef, useState, useSyncExternalStore } from "react";
import {
  TeremoqPlayerEngine,
  initialPlayerSnapshot,
  type PlayerPhase,
  type PlayerReason,
  type VideoTrackId,
} from "@/lib/player/engine";
import {
  loadGatewaySnapshot,
  loadPlaybackConfiguration,
  type GatewaySignalSnapshot,
} from "@/lib/supervisor/api";
import { LatencyWindow, type LatencyPercentiles } from "@/lib/player/latency-window";
import {
  decodeVisualTimecodeRow,
  visualTimecodeLatencyMs,
  visualTimecodeRegion,
} from "@/lib/player/visual-timecode";
import styles from "./teremoq-player.module.css";
import {
  playerDataPolicy,
  type PlayerDeployment,
} from "@/lib/lan-lab/config";

const INPUT_LATENCY_SAMPLES = 512;
const EMPTY_LATENCY: LatencyPercentiles = {
  samples: 0,
  p50Ms: null,
  p95Ms: null,
  p99Ms: null,
};
const LAN_TRACKS = ["VIDEO HQ", "VIDEO LQ", "AUDIO CRÍTICO", "TELEMETRÍA"] as const;

type Capability = {
  label: string;
  supported: boolean;
};

export function TeremoqPlayer({ deployment }: { deployment: PlayerDeployment }) {
  const lanLab = deployment.mode === "lan-lab";
  const policy = playerDataPolicy(deployment);
  const configurationAvailable =
    deployment.mode === "loopback" || deployment.configurationStatus === "available";
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const inputFrameRef = useRef<HTMLIFrameElement>(null);
  const engineRef = useRef<TeremoqPlayerEngine | null>(null);
  const uiGenerationRef = useRef(0);
  const [snapshot, setSnapshot] = useState(() => initialPlayerSnapshot(deployment));
  const [selectedVideoTrack, setSelectedVideoTrack] = useState<VideoTrackId>(0);
  const [inputPreviewUrl, setInputPreviewUrl] = useState<string | null>(null);
  const [inputMessage, setInputMessage] = useState(
    lanLab ? "Preview de entrada no disponible en el paquete LAN" : "Leyendo configuración del observador",
  );
  const [inputFrameReady, setInputFrameReady] = useState(false);
  const [inputMediaPlaying, setInputMediaPlaying] = useState(false);
  const [inputLatencyWindow] = useState(() => new LatencyWindow(INPUT_LATENCY_SAMPLES));
  const [inputSourceLatency, setInputSourceLatency] = useState(EMPTY_LATENCY);
  const [gatewaySnapshot, setGatewaySnapshot] = useState<GatewaySignalSnapshot | null>(null);
  const browserMounted = useSyncExternalStore(
    subscribeToNothing,
    clientSnapshot,
    serverSnapshot,
  );
  const capabilities: Capability[] = browserMounted
    ? [
        { label: "WebTransport", supported: "WebTransport" in window },
        { label: "VideoDecoder", supported: "VideoDecoder" in window },
        { label: "EncodedVideoChunk", supported: "EncodedVideoChunk" in window },
      ]
    : [];
  const compatible =
    capabilities.length > 0 && capabilities.every(({ supported }) => supported);
  const active = snapshot.running;
  const playing = snapshot.running && snapshot.frames > 0;
  const effectivePhase: PlayerPhase = !configurationAvailable || (browserMounted && !compatible)
    ? "unavailable"
    : snapshot.phase;
  const effectiveReason: PlayerReason = !configurationAvailable
    ? "configuration-invalid"
    : browserMounted && !compatible
      ? "browser-unsupported"
      : snapshot.reason;
  const activeTracks =
    gatewaySnapshot?.tracks.filter((track) => track.status === "active").length ?? 0;

  useEffect(() => {
    let stopped = false;
    let timer: number | null = null;
    const controller = new AbortController();

    const cleanup = () => {
      stopped = true;
      uiGenerationRef.current += 1;
      controller.abort();
      if (timer !== null) window.clearTimeout(timer);
      engineRef.current?.stop();
      engineRef.current = null;
    };

    if (!policy.loadGatewayPlayback || !policy.pollGatewaySnapshot) {
      return cleanup;
    }

    void loadPlaybackConfiguration(controller.signal)
      .then((configuration) => {
        if (stopped) return;
        setInputPreviewUrl(configuration.inputPreviewUrl);
        setInputMessage(
          configuration.inputPreviewUrl
            ? "Observador configurado; esperando señal SRT"
            : "Observador de entrada no configurado",
        );
      })
      .catch((cause: unknown) => {
        if (!stopped) setInputMessage(toMessage(cause));
      });

    const refreshSnapshot = async () => {
      try {
        const current = await loadGatewaySnapshot(controller.signal);
        if (!stopped) {
          setGatewaySnapshot(current);
          setInputMessage(current.inputActive ? "Señal SRT activa" : "Esperando señal SRT");
        }
      } catch (cause: unknown) {
        if (!stopped) setInputMessage(toMessage(cause));
      } finally {
        if (!stopped) timer = window.setTimeout(() => void refreshSnapshot(), 1_000);
      }
    };
    void refreshSnapshot();

    return cleanup;
  }, [policy.loadGatewayPlayback, policy.pollGatewaySnapshot]);

  useEffect(() => {
    if (!inputFrameReady || !inputPreviewUrl) return;
    let stopped = false;
    let lastTimecodeMs: number | null = null;
    const region = visualTimecodeRegion();
    const timecodeCanvas = document.createElement("canvas");
    timecodeCanvas.width = region.width;
    timecodeCanvas.height = 1;
    const timecodeContext = timecodeCanvas.getContext("2d", { willReadFrequently: true });
    const ensurePlayback = () => {
      try {
        const video = inputFrameRef.current?.contentDocument?.querySelector("video");
        if (!video) return;
        video.muted = true;
        video.playsInline = true;
        if (video.paused && video.readyState >= HTMLMediaElement.HAVE_CURRENT_DATA) {
          void video.play().catch(() => undefined);
        }
        if (!stopped) {
          const playingNow = !video.paused && video.readyState >= HTMLMediaElement.HAVE_CURRENT_DATA;
          setInputMediaPlaying(playingNow);
          const frameRegion = visualTimecodeRegion(video.videoWidth, video.videoHeight);
          if (
            playingNow &&
            timecodeContext &&
            video.videoWidth >= frameRegion.x + frameRegion.width &&
            video.videoHeight > frameRegion.y
          ) {
            timecodeContext.drawImage(
              video,
              frameRegion.x,
              frameRegion.y,
              frameRegion.width,
              1,
              0,
              0,
              frameRegion.width,
              1,
            );
            const timecodeMs = decodeVisualTimecodeRow(
              timecodeContext.getImageData(0, 0, region.width, 1).data,
              frameRegion.stride,
            );
            if (timecodeMs !== null && timecodeMs !== lastTimecodeMs) {
              lastTimecodeMs = timecodeMs;
              const latencyMs = visualTimecodeLatencyMs(
                timecodeMs,
                performance.timeOrigin + performance.now(),
              );
              if (latencyMs !== null) {
                inputLatencyWindow.record(latencyMs);
                setInputSourceLatency(inputLatencyWindow.snapshot());
              }
            }
          }
        }
      } catch {
        if (!stopped) setInputMediaPlaying(false);
      }
    };
    ensurePlayback();
    const timer = window.setInterval(ensurePlayback, 250);
    return () => {
      stopped = true;
      window.clearInterval(timer);
    };
  }, [inputFrameReady, inputLatencyWindow, inputPreviewUrl]);

  const startSession = async (trackId: VideoTrackId) => {
    const canvas = canvasRef.current;
    if (!canvas || !compatible || !configurationAvailable) return;
    const generation = ++uiGenerationRef.current;
    engineRef.current?.stop();
    const engine = new TeremoqPlayerEngine(
      canvas,
      (nextSnapshot) => {
        if (uiGenerationRef.current === generation) setSnapshot(nextSnapshot);
      },
      trackId,
      deployment,
    );
    engineRef.current = engine;
    try {
      await engine.start();
      if (uiGenerationRef.current !== generation) engine.stop();
    } catch {
      // El engine ya publica el error específico en su snapshot.
    }
  };

  const toggleSession = async () => {
    if (engineRef.current && snapshot.running) {
      engineRef.current.stop();
      uiGenerationRef.current += 1;
      engineRef.current = null;
      return;
    }
    await startSession(selectedVideoTrack);
  };

  const selectVideoTrack = (trackId: VideoTrackId) => {
    if (trackId === selectedVideoTrack) return;
    const reconnect = snapshot.running;
    uiGenerationRef.current += 1;
    engineRef.current?.stop();
    engineRef.current = null;
    setSnapshot(initialPlayerSnapshot(deployment));
    setSelectedVideoTrack(trackId);
    if (reconnect) void startSession(trackId);
  };

  return (
    <section className={styles.grid} aria-label="Reproductor Teremoq">
      <section className={styles.trackOverview} aria-label="Estado de las pistas MoQT">
        <div className={styles.trackOverviewHeader}>
          <div>
            <p className={styles.kicker}>MATRIZ DE PISTAS MoQT</p>
            <h2>Señales publicadas por el Gateway</h2>
          </div>
          <strong data-complete={activeTracks === 4}>
            {gatewaySnapshot
              ? `${activeTracks} / 4 ACTIVAS`
              : lanLab
                ? "SALUD NO MEDIDA"
                : "LEYENDO GATEWAY…"}
          </strong>
        </div>

        <div className={styles.trackMatrix}>
          {gatewaySnapshot ? gatewaySnapshot.tracks.map((track) => (
            <div key={track.id} data-active={track.status === "active"}>
              <div className={styles.trackCardHeader}>
                <span className={styles.trackIdentity}>TRACK {track.id}</span>
                <span className={styles.trackStatus}>{trackStatusLabel(track.status)}</span>
              </div>
              <strong>{track.label}</strong>
              <div className={styles.trackCardFooter}>
                <span>{track.codec?.toUpperCase() ?? "SIN CODEC"}</span>
                <span>{trackPresentationLabel(track.id, selectedVideoTrack, playing)}</span>
                <span>{track.objects.toLocaleString("es-ES")} OBJ</span>
              </div>
            </div>
          )) : lanLab ? LAN_TRACKS.map((label, trackId) => (
            <div key={label} data-active="false">
              <div className={styles.trackCardHeader}>
                <span className={styles.trackIdentity}>TRACK {trackId}</span>
                <span className={styles.trackStatus}>NO MEDIDA</span>
              </div>
              <strong>{label}</strong>
              <div className={styles.trackCardFooter}>
                <span>SIN DATO</span>
                <span>{trackId === selectedVideoTrack ? "PLAYER SELECCIONADO" : "NO MEDIDO"}</span>
                <span>OBJ —</span>
              </div>
            </div>
          )) : <span className={styles.checking}>Leyendo Tracks…</span>}
        </div>

        <div className={styles.telemetryPanel} data-live={snapshot.telemetry !== null}>
          <div>
            <span>TRACK 3 · TELEMETRÍA</span>
            <strong>
              {snapshot.telemetry
                ? "DATOS EN VIVO"
                : lanLab
                  ? "NO MEDIDA"
                  : "ESPERANDO SUSCRIPCIÓN"}
            </strong>
          </div>
          <TelemetryValue label="Vehículo" value={snapshot.telemetry?.vehicle ?? "—"} />
          <TelemetryValue
            label="Velocidad"
            value={snapshot.telemetry ? `${snapshot.telemetry.speedKph.toFixed(0)} km/h` : "—"}
          />
          <TelemetryValue
            label="Latitud"
            value={snapshot.telemetry?.latitude.toFixed(7) ?? "—"}
          />
          <TelemetryValue
            label="Longitud"
            value={snapshot.telemetry?.longitude.toFixed(7) ?? "—"}
          />
          <TelemetryValue
            label="Secuencia"
            value={snapshot.telemetry?.sequence.toLocaleString("es-ES") ?? "—"}
          />
        </div>
      </section>

      <div className={`${styles.monitor} ${styles.inputMonitor}`}>
        <div className={styles.monitorHeader}>
          <span className={styles.liveIndicator} data-active={inputMediaPlaying}>
            INPUT · SRT OBSERVER
          </span>
          <span>SRT TAP → WEBRTC</span>
        </div>
        <div className={styles.viewport}>
          {inputPreviewUrl ? (
            <iframe
              ref={inputFrameRef}
              className={styles.inputFrame}
              src={inputPreviewUrl}
              title="Señal SRT de entrada"
              allow="autoplay; fullscreen; picture-in-picture"
              referrerPolicy="no-referrer"
              onLoad={() => {
                inputLatencyWindow.clear();
                setInputSourceLatency(EMPTY_LATENCY);
                setInputFrameReady(true);
                setInputMediaPlaying(false);
              }}
            />
          ) : (
            <div className={styles.reticle} aria-hidden="true" />
          )}
          {inputMediaPlaying && <span className={styles.onAir}>LIVE · SRT INPUT</span>}
          {(!inputPreviewUrl || !inputFrameReady) && (
            <div className={styles.emptyState}>
              <strong>
                {lanLab
                  ? "Entrada no disponible"
                  : gatewaySnapshot?.inputActive
                    ? "Señal detectada"
                    : "Entrada pendiente"}
              </strong>
              <span>{inputMessage}</span>
            </div>
          )}
        </div>
        <div className={`${styles.metrics} ${styles.outputMetrics}`}>
          <Metric
            label="Estado"
            value={
              lanLab
                ? "No disponible"
                : inputMediaPlaying
                  ? "WebRTC activo"
                  : gatewaySnapshot?.inputActive
                    ? "SRT activo"
                    : "Esperando"
            }
            accent={inputMediaPlaying}
          />
          <Metric
            label="Paquetes SRT"
            value={gatewaySnapshot?.sourcePackets.toLocaleString("es-ES") ?? "—"}
          />
          <Metric label="G2G entrada p50" value={formatLatency(inputSourceLatency.p50Ms)} />
          <Metric label="G2G entrada p95" value={formatLatency(inputSourceLatency.p95Ms)} />
          <Metric label="G2G entrada p99" value={formatLatency(inputSourceLatency.p99Ms)} />
          <Metric
            label="Ingest → Pub p95"
            value={
              gatewaySnapshot?.ingestToPublishP95Ms === null || !gatewaySnapshot
                ? "—"
                : `${gatewaySnapshot.ingestToPublishP95Ms} ms`
            }
          />
        </div>
        <p className={styles.tapNote}>
          {lanLab
            ? "Fuente local de configuración · métricas Gateway no medidas"
            : `Tap prescindible · ${formatLocation(gatewaySnapshot)} · ${gatewaySnapshot ? formatBytes(gatewaySnapshot.sourceBytes) : "sin datos"}${inputSourceLatency.samples > 0 ? ` · timecode visual ±10 ms · n=${inputSourceLatency.samples.toLocaleString("es-ES")}` : " · timecode no detectado"}`}
        </p>
      </div>

      <div className={styles.monitor}>
        <div className={styles.monitorHeader}>
          <span className={styles.liveIndicator} data-active={playing}>
            TRACK {selectedVideoTrack} · VIDEO {selectedVideoTrack === 0 ? "HQ" : "LQ"}
          </span>
          <span>WEBCODECS → CANVAS</span>
        </div>
        <div className={styles.viewport}>
          <canvas
            ref={canvasRef}
            className={styles.canvas}
            width={1280}
            height={720}
            aria-label="Salida de vídeo decodificada"
          />
          {!playing && <div className={styles.reticle} aria-hidden="true" />}
          {!playing && (
            <div className={styles.emptyState}>
              <strong>{phaseLabel(effectivePhase)}</strong>
              <span>{snapshot.message}</span>
            </div>
          )}
          {playing && <span className={styles.onAir}>LIVE · TRACK {selectedVideoTrack}</span>}
        </div>
        <div className={`${styles.metrics} ${styles.outputMetrics}`}>
          <Metric label="Estado" value={phaseLabel(effectivePhase)} accent={playing} />
          <Metric label="Frames canvas" value={snapshot.frames.toLocaleString("es-ES")} />
          <Metric label="G2G salida p50" value={formatLatency(snapshot.sourceToCanvasP50Ms)} />
          <Metric label="G2G salida p95" value={formatLatency(snapshot.sourceToCanvasP95Ms)} />
          <Metric label="G2G salida p99" value={formatLatency(snapshot.sourceToCanvasP99Ms)} />
          <Metric
            label="RX → Canvas p95"
            value={formatLatency(snapshot.rxToCanvasP95Ms)}
          />
        </div>
      </div>

      <aside className={styles.controls}>
        <div>
          <p className={styles.kicker}>SESSION CONTROL</p>
          <h2>Salida MoQT</h2>
        </div>

        <div className={styles.field}>
          <span>Relay WebTransport</span>
          <output>{snapshot.relayLabel}</output>
        </div>

        <div className={styles.trackSelector} aria-label="Selección de pista de vídeo">
          <span>PISTA DEL PLAYER</span>
          <div>
            <button
              type="button"
              data-track="0"
              data-selected={selectedVideoTrack === 0}
              aria-pressed={selectedVideoTrack === 0}
              onClick={() => selectVideoTrack(0)}
            >
              TRACK 0 · HQ
            </button>
            <button
              type="button"
              data-track="1"
              data-selected={selectedVideoTrack === 1}
              aria-pressed={selectedVideoTrack === 1}
              onClick={() => selectVideoTrack(1)}
            >
              TRACK 1 · LQ
            </button>
          </div>
        </div>

        <div className={styles.capabilities}>
          <p>CAPACIDADES DEL NAVEGADOR</p>
          {capabilities.length === 0 ? (
            <span className={styles.checking}>Comprobando…</span>
          ) : (
            capabilities.map(({ label, supported }) => (
              <div key={label}>
                <span>{label}</span>
                <span className={supported ? styles.ok : styles.missing}>
                  {supported ? "DISPONIBLE" : "NO DISPONIBLE"}
                </span>
              </div>
            ))
          )}
        </div>

        <div className={styles.detailGrid}>
          <Detail label="Codec" value={snapshot.codec} />
          <Detail label="Decoder queue" value={String(snapshot.decoderQueue)} />
          <Detail label="Descartes cliente" value={String(snapshot.dropped)} />
          <Detail label="Motivo" value={reasonLabel(effectiveReason)} />
          {lanLab && (
            <Detail
              label="Configuración"
              value={configurationAvailable ? "LOCAL · VALIDADA" : "LOCAL · NO DISPONIBLE"}
            />
          )}
          <Detail label="Reintento" value={snapshot.reconnectAttempt === 0 ? "—" : String(snapshot.reconnectAttempt)} />
          <Detail
            label="Cola Gateway"
            value={gatewaySnapshot?.schedulerQueuedObjects.toLocaleString("es-ES") ?? "—"}
          />
          <Detail
            label="Descartes Gateway"
            value={gatewaySnapshot?.schedulerDropped.toLocaleString("es-ES") ?? "—"}
          />
          <Detail
            label="Expulsiones críticas"
            value={gatewaySnapshot?.schedulerEvicted.toLocaleString("es-ES") ?? "—"}
          />
          <Detail
            label="Último PTS"
            value={snapshot.lastTimestampUs === null ? "—" : `${(snapshot.lastTimestampUs / 1_000_000).toFixed(3)} s`}
          />
          <Detail label="Muestras RX → Canvas" value={snapshot.rxToCanvasSamples.toLocaleString("es-ES")} />
          <Detail label="Última RX → Canvas" value={formatLatency(snapshot.rxToCanvasMs)} />
          <Detail label="Origen → RX p50" value={formatLatency(snapshot.sourceToRxP50Ms)} />
          <Detail label="Origen → RX p95" value={formatLatency(snapshot.sourceToRxP95Ms)} />
          <Detail label="RX → Canvas p50" value={formatLatency(snapshot.rxToCanvasP50Ms)} />
          <Detail label="RX → Canvas p99" value={formatLatency(snapshot.rxToCanvasP99Ms)} />
          <Detail label="Muestras G2G salida" value={snapshot.sourceToCanvasSamples.toLocaleString("es-ES")} />
          <Detail
            label="Δ salida − entrada p50"
            value={formatLatencyDelta(snapshot.sourceToCanvasP50Ms, inputSourceLatency.p50Ms)}
          />
          <Detail
            label="Calidad timecode"
            value={snapshot.sourceToCanvasSamples > 0 ? "VISUAL · MISMO HOST · ±10 MS" : "NO DISPONIBLE"}
          />
        </div>

        <div
          className={styles.browserState}
          data-ready={compatible}
          data-state={effectivePhase}
          role="status"
          aria-live="polite"
          aria-atomic="true"
        >
          <span className={styles.stateDot} />
          <div>
            <strong>
              {configurationAvailable && compatible ? phaseLabel(snapshot.phase) : "No disponible"}
            </strong>
            <p>
              {!configurationAvailable
                ? "Configuración LAN local ausente o inválida."
                : compatible
                  ? snapshot.message
                  : "El player requiere WebTransport y WebCodecs."}
            </p>
          </div>
        </div>

        <button
          type="button"
          data-testid="connect-player"
          disabled={!compatible || !configurationAvailable}
          onClick={() => void toggleSession()}
        >
          {active ? "Detener sesión" : `Conectar Track ${selectedVideoTrack}`}
        </button>
        <p className={styles.note}>
          {lanLab
            ? "Recuperación manual disponible tras agotar el backoff: vuelve a conectar sin recargar ni crear reintentos ilimitados."
            : "G2G solo aparece al validar el timecode visual del fixture. En otras fuentes permanece no disponible."}
        </p>
      </aside>
    </section>
  );
}

function Metric({ label, value, accent = false }: { label: string; value: string; accent?: boolean }) {
  return (
    <div>
      <span>{label}</span>
      <strong className={accent ? styles.accent : undefined}>{value}</strong>
    </div>
  );
}

function Detail({ label, value }: { label: string; value: string }) {
  return (
    <div>
      <span>{label}</span>
      <strong>{value}</strong>
    </div>
  );
}

function TelemetryValue({ label, value }: { label: string; value: string }) {
  return (
    <div>
      <span>{label}</span>
      <strong>{value}</strong>
    </div>
  );
}

function phaseLabel(phase: PlayerPhase) {
  const labels: Record<PlayerPhase, string> = {
    waiting: "Esperando",
    connecting: "Conectando",
    active: "Reproduciendo",
    degraded: "Degradado",
    stale: "Sin actividad",
    unavailable: "No disponible",
    closed: "Cerrado",
  };
  return labels[phase];
}

function reasonLabel(reason: PlayerReason) {
  const labels: Record<PlayerReason, string> = {
    "operator-waiting": "INICIO PENDIENTE",
    connecting: "NEGOCIACIÓN LOCAL",
    "media-waiting": "ESPERANDO KEYFRAME",
    healthy: "SEÑAL ACTUAL",
    "video-pressure": "PRESIÓN DE VÍDEO",
    "video-stale": "VÍDEO SIN ACTIVIDAD",
    "peer-silent": "PEER SILENCIOSO",
    "network-unreachable": "RED NO DISPONIBLE",
    "retry-exhausted": "REINTENTOS AGOTADOS",
    "configuration-invalid": "CONFIGURACIÓN INVÁLIDA",
    "trust-invalid": "TRUST NO VÁLIDO",
    "protocol-incompatible": "PROTOCOLO INCOMPATIBLE",
    "decoder-unavailable": "DECODER NO DISPONIBLE",
    "media-invalid": "MEDIA INVÁLIDA",
    "browser-unsupported": "BROWSER NO COMPATIBLE",
    "operator-closed": "CIERRE DEL OPERADOR",
  };
  return labels[reason];
}

function trackStatusLabel(status: GatewaySignalSnapshot["tracks"][number]["status"]) {
  const labels = {
    active: "ACTIVA",
    stale: "SIN ACTIVIDAD",
    waiting: "ESPERANDO",
    unavailable: "NO DISPONIBLE",
  } as const;
  return labels[status];
}

function trackPresentationLabel(
  trackId: number,
  selectedVideoTrack: VideoTrackId,
  playing: boolean,
) {
  if (trackId === 0 || trackId === 1) {
    return playing && trackId === selectedVideoTrack ? "PLAYER ACTIVO" : "PLAYER DISPONIBLE";
  }
  if (trackId === 2) return "AUDIO PUBLICADO";
  return "DATOS PUBLICADOS";
}

function subscribeToNothing() {
  return () => undefined;
}

function clientSnapshot() {
  return true;
}

function serverSnapshot() {
  return false;
}

function formatLocation(snapshot: GatewaySignalSnapshot | null) {
  if (snapshot?.trackGroup === null || snapshot?.trackObject === null || !snapshot) return "—";
  return `G${snapshot.trackGroup} · O${snapshot.trackObject}`;
}

function formatBytes(bytes: number) {
  if (bytes < 1_000_000) return `${(bytes / 1_000).toFixed(1)} kB recibidos`;
  if (bytes < 1_000_000_000) return `${(bytes / 1_000_000).toFixed(1)} MB recibidos`;
  return `${(bytes / 1_000_000_000).toFixed(2)} GB recibidos`;
}

function formatLatency(valueMs: number | null) {
  return valueMs === null ? "—" : `${valueMs.toFixed(1)} ms`;
}

function formatLatencyDelta(outputMs: number | null, inputMs: number | null) {
  if (outputMs === null || inputMs === null) return "—";
  const delta = outputMs - inputMs;
  return `${delta >= 0 ? "+" : ""}${delta.toFixed(1)} ms`;
}

function toMessage(_cause: unknown) {
  void _cause;
  return "Datos locales no disponibles";
}
