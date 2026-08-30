"use client";

import { useEffect, useRef, useState, useSyncExternalStore } from "react";
import {
  exportLanLoadMetrics,
  isCollectibleLanLoadSnapshot,
  LanLoadGenerator,
  LAN_LOAD_LEVELS,
  type LanLoadLevel,
  type LanLoadSnapshot,
} from "../lib/lan-lab/load-generator";
import type { PlayerDeployment } from "../lib/lan-lab/config";
import styles from "./lan-load-generator.module.css";

const EMPTY: LanLoadSnapshot = Object.freeze({
  schemaVersion: 1,
  phase: "idle",
  requested: 0,
  connected: 0,
  active: 0,
  activeSessionsPeak: 0,
  closed: 0,
  objectsObserved: 0,
  bytesObserved: 0,
  localStreamRejections: 0,
  errors: 0,
  reconnectAttempts: 0,
  sessionLosses: 0,
  sessionRecoveries: 0,
  lastSessionRecoveryMs: null,
  firstConnectedMs: null,
  allActiveMs: null,
  lastObjectMs: null,
  elapsedMs: null,
  lastError: null,
  runId: null,
  sourceCommit: null,
  startedAtUtc: null,
  endedAtUtc: null,
});

export function LanLoadGeneratorPanel({
  deployment,
  initialLevel,
}: {
  deployment: PlayerDeployment;
  initialLevel: LanLoadLevel | null;
}) {
  const generatorRef = useRef<LanLoadGenerator | null>(null);
  const [snapshot, setSnapshot] = useState(EMPTY);
  const browserMounted = useSyncExternalStore(subscribeToNothing, clientSnapshot, serverSnapshot);
  const webTransportAvailable = browserMounted ? "WebTransport" in window : null;
  const [busy, setBusy] = useState(false);
  const configurationAvailable =
    deployment.mode === "lan-lab" && deployment.configurationStatus === "available";
  const runnable = configurationAvailable && webTransportAvailable === true;
  const measured = snapshot.requested > 0;
  const collectible = isCollectibleLanLoadSnapshot(snapshot);

  useEffect(() => {
    let mounted = true;
    const supported = "WebTransport" in window;
    const generator = new LanLoadGenerator(deployment, (next) => {
      if (mounted) setSnapshot(next);
    });
    generatorRef.current = generator;
    if (supported && configurationAvailable && initialLevel !== null) {
      void generator.start(initialLevel);
    }
    return () => {
      mounted = false;
      generatorRef.current = null;
      void generator.stop();
    };
  }, [configurationAvailable, deployment, initialLevel]);

  const start = async (level: LanLoadLevel) => {
    if (!runnable || busy) return;
    setBusy(true);
    try {
      await generatorRef.current?.start(level);
    } finally {
      setBusy(false);
    }
  };

  const stop = async () => {
    if (busy) return;
    setBusy(true);
    try {
      await generatorRef.current?.stop();
    } finally {
      setBusy(false);
    }
  };

  const download = () => {
    if (!collectible) return;
    const contents = `${JSON.stringify(exportLanLoadMetrics(snapshot), null, 2)}\n`;
    const url = URL.createObjectURL(new Blob([contents], { type: "application/json" }));
    const link = document.createElement("a");
    link.href = url;
    link.download = `teremoq-lan-load-${snapshot.requested}.json`;
    link.click();
    URL.revokeObjectURL(url);
  };

  return (
    <section className={styles.panel} aria-labelledby="load-heading">
      <div className={styles.headingRow}>
        <div>
          <p className={styles.eyebrow}>SESIONES LIGERAS / SÓLO OBSERVACIÓN</p>
          <h2 id="load-heading">Carga WebTransport + MoQT</h2>
        </div>
        <output className={styles.phase} aria-live="polite" data-phase={snapshot.phase}>
          {phaseLabel(snapshot.phase)}
        </output>
      </div>

      <p className={styles.explanation}>
        Cada cliente abre una sesión TLS fijada al fingerprint del banco y permitida por
        su política IP, con la misma configuración local, y se
        suscribe a vídeo LQ. Consume Objects sin decodificar ni renderizar. No consulta
        Gateway, entrada ni Operaciones.
      </p>

      {!configurationAvailable && (
        <p className={styles.notice} role="status">
          Configuración local no disponible. No se iniciará ninguna sesión.
        </p>
      )}
      {webTransportAvailable === false && (
        <p className={styles.notice} role="status">
          WebTransport no está disponible en este navegador. No se iniciará ninguna sesión.
        </p>
      )}

      <fieldset className={styles.controls} disabled={!runnable || busy}>
        <legend>Selecciona una cardinalidad permitida</legend>
        {LAN_LOAD_LEVELS.map((level) => (
          <button key={level} type="button" onClick={() => void start(level)}>
            INICIAR {level}
          </button>
        ))}
      </fieldset>

      <div className={styles.secondaryControls}>
        <button
          type="button"
          onClick={() => void stop()}
          disabled={busy || !measured || snapshot.phase === "closed"}
        >
          DETENER Y LIMPIAR
        </button>
        <button type="button" onClick={download} disabled={!collectible || busy}>
          EXPORTAR JSON LOCAL
        </button>
      </div>

      <dl className={styles.metrics} aria-label="Métricas locales observadas">
        <Metric label="Solicitadas" value={measured ? snapshot.requested : null} />
        <Metric label="Conectadas" value={measured ? snapshot.connected : null} />
        <Metric label="Activas" value={measured ? snapshot.active : null} />
        <Metric label="Pico de sesiones activas" value={measured ? snapshot.activeSessionsPeak : null} />
        <Metric label="Cerradas acumuladas" value={measured ? snapshot.closed : null} />
        <Metric label="Objects observados" value={measured ? snapshot.objectsObserved : null} />
        <Metric label="Bytes observados" value={measured ? snapshot.bytesObserved : null} />
        <Metric label="Reintentos" value={measured ? snapshot.reconnectAttempts : null} />
        <Metric label="Pérdidas de sesión" value={measured ? snapshot.sessionLosses : null} />
        <Metric label="Recuperaciones" value={measured ? snapshot.sessionRecoveries : null} />
        <Metric label="Última recuperación" value={formatMs(snapshot.lastSessionRecoveryMs)} />
        <Metric label="Errores redactados" value={measured ? snapshot.errors : null} />
        <Metric label="Primera conexión" value={formatMs(snapshot.firstConnectedMs)} />
        <Metric label="Todas activas" value={formatMs(snapshot.allActiveMs)} />
        <Metric label="Último Object" value={formatMs(snapshot.lastObjectMs)} />
        <Metric label="Tiempo observado" value={formatMs(snapshot.elapsedMs)} />
      </dl>

      <div className={styles.measurementPolicy}>
        <p>
          Último error: <strong>{snapshot.lastError ?? "ninguno observado"}</strong>
        </p>
        <p>Pérdida QUIC y jitter QUIC: <strong>no medidos</strong>.</p>
        <p>Los contadores proceden sólo de callbacks observados en este navegador.</p>
        <p>La exportación se habilita tras detener y cerrar todas las sesiones con tráfico observado.</p>
      </div>
    </section>
  );
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

function Metric({ label, value }: { label: string; value: string | number | null }) {
  return (
    <div>
      <dt>{label}</dt>
      <dd>{value ?? "NO MEDIDO"}</dd>
    </div>
  );
}

function formatMs(value: number | null) {
  return value === null ? null : `${value} ms`;
}

function phaseLabel(phase: LanLoadSnapshot["phase"]) {
  const labels: Record<LanLoadSnapshot["phase"], string> = {
    idle: "SIN EJECUCIÓN",
    starting: "INICIANDO",
    active: "ACTIVA",
    recovering: "RECUPERANDO",
    degraded: "DEGRADADA",
    stopping: "CERRANDO",
    closed: "CERRADA",
    unavailable: "NO DISPONIBLE",
  };
  return labels[phase];
}
