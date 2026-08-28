"use client";

import { useEffect, useState } from "react";
import { loadControlPlaneSimulation } from "../lib/operations/control-plane-adapter";
import { loadOperationsGatewaySnapshot } from "../lib/operations/gateway-adapter";
import { SingleFlightPoller, type PollEvent } from "../lib/operations/poller";
import {
  datum,
  type ControlPlaneSimulationSnapshot,
  type Datum,
  type GatewayOperationsSnapshot,
  type OperationsSourceState,
} from "../lib/operations/types";
import styles from "./operations-dashboard.module.css";

const INITIAL_GATEWAY: OperationsSourceState<GatewayOperationsSnapshot> = {
  health: "loading",
  snapshot: null,
  reason: "loading",
  lastSuccessAt: null,
};
const INITIAL_CONTROL: OperationsSourceState<ControlPlaneSimulationSnapshot> = {
  health: "loading",
  snapshot: null,
  reason: "loading",
  lastSuccessAt: null,
};

const CONTROL_REQUIREMENTS =
  "Requiere autenticación, RBAC, CSRF, auditoría, límites de coste, idempotencia, confirmación crítica, rollback, kill switch e integración aceptada.";

export function OperationsDashboard() {
  const [gateway, setGateway] = useState(INITIAL_GATEWAY);
  const [control, setControl] = useState(INITIAL_CONTROL);

  useEffect(() => {
    const gatewayPoller = new SingleFlightPoller(
      loadOperationsGatewaySnapshot,
      (event) => setGateway((current) => reduceSource(current, event)),
      undefined,
      { intervalMs: 1_000, timeoutMs: 2_500, maximumIntervalMs: 15_000 },
    );
    const controlPoller = new SingleFlightPoller(
      loadControlPlaneSimulation,
      (event) => setControl((current) => reduceSource(current, event)),
      undefined,
      { intervalMs: 5_000, timeoutMs: 2_500, maximumIntervalMs: 30_000 },
    );
    gatewayPoller.start();
    controlPoller.start();
    return () => {
      gatewayPoller.stop();
      controlPoller.stop();
    };
  }, []);

  return <OperationsView gateway={gateway} control={control} />;
}

export function OperationsView({
  gateway,
  control,
}: {
  gateway: OperationsSourceState<GatewayOperationsSnapshot>;
  control: OperationsSourceState<ControlPlaneSimulationSnapshot>;
}) {
  const gatewaySnapshot = gateway.health === "available" ? gateway.snapshot : null;
  const gatewayOperational = gatewaySnapshot !== null && gatewaySnapshot.phases.length > 0;
  const controlSnapshot = control.health === "available" ? control.snapshot : null;
  const gatewayObservedAt = gatewaySnapshot?.receivedAt ?? null;
  const gatewayAge = gatewaySnapshot
    ? Math.max(...gatewaySnapshot.phases.map(({ ageMs }) => ageMs ?? 0), 0)
    : null;
  const controlAge = null;
  const phase = (id: GatewayOperationsSnapshot["phases"][number]["id"]) =>
    gatewaySnapshot?.phases.find((item) => item.id === id) ?? null;
  const ingest = phase("srt_ingest");
  const demux = phase("mpegts_demux");
  const distribution = phase("moq_distribution");
  const capacityTotal = controlSnapshot?.placements
    .filter(({ role }) => role === "core")
    .reduce((total, node) => total + node.capacityViewers, 0) ?? null;
  const capacityReserved = controlSnapshot?.reservedViewers ?? null;
  const capacityAvailable =
    capacityTotal !== null && controlSnapshot
      ? Math.max(0, capacityTotal - controlSnapshot.activeSessions - controlSnapshot.reservedViewers)
      : null;
  const utilization =
    capacityTotal !== null && capacityTotal > 0 && controlSnapshot
      ? (controlSnapshot.activeSessions / capacityTotal) * 100
      : null;

  const gatewayDatum = <T,>(value: T | null, ageMs = gatewayAge) => {
    const safeValue = gatewayOperational ? value : null;
    return datum(safeValue, safeValue === null ? "not-available" : "measured", "gateway-real", gatewayObservedAt, ageMs);
  };
  const controlDatum = <T,>(value: T | null) =>
    datum(
      value,
      value === null ? "not-measured" : "local-simulation",
      "control-plane-simulation",
      controlSnapshot?.observedAt ?? null,
      controlAge,
    );
  const pending = <T,>() => datum<T>(null, "pending-integration", "cloud-future", null, null);
  const externalEstimate = datum(
    controlSnapshot?.estimatedCost.amount ?? null,
    controlSnapshot?.estimatedCost.amount === null || !controlSnapshot ? "not-measured" : "local-simulation",
    "cloud-future",
    controlSnapshot?.observedAt ?? null,
    controlAge,
  );

  const statusText = gatewayOperational && gatewaySnapshot
    ? gatewaySnapshot.phases.some(({ status }) => status === "active")
      ? "Señal activa observada"
      : "Gateway disponible, sin actividad reciente"
    : gatewaySnapshot
      ? "Monitor Gateway temporalmente no disponible"
      : gateway.reason === "data-rejected"
      ? "Datos Gateway rechazados"
      : "Gateway no disponible";

  return (
    <div className={styles.dashboard}>
      <section className={styles.sourceStrip} aria-labelledby="sources-heading">
        <div>
          <p className={styles.eyebrow}>FUENTES Y CALIDAD</p>
          <h2 id="sources-heading">Qué sabemos ahora</h2>
        </div>
        <SourceBadge label="Gateway" state={gateway} provenance="gateway-real" />
        <SourceBadge label="Plano de control" state={control} provenance="control-plane-simulation" />
        <SourceBadge label="Cloud" state={null} provenance="cloud-future" />
      </section>

      <section className={styles.section} aria-labelledby="summary-heading">
        <SectionHeading eyebrow="01 / EVENTO" id="summary-heading" title="Resumen del evento" />
        <div className={styles.heroGrid}>
          <article className={styles.heroStatus}>
            <p>ESTADO GENERAL</p>
            <h3>{statusText}</h3>
            <span>Vista read-only; fuera del camino crítico de vídeo y autoescalado.</span>
            <DatumMeta datum={gatewayDatum(gatewayOperational ? statusText : null)} />
          </article>
          <MetricCard label="Evento activo" datum={pending<string>()} />
          <MetricCard label="Entrada SRT" datum={gatewayDatum(ingest?.status ?? null, ingest?.ageMs ?? null)} />
          <MetricCard label="Distribución MoQT" datum={gatewayDatum(distribution?.status ?? null, distribution?.ageMs ?? null)} />
          <MetricCard label="Gateway ↔ relay" datum={gatewayDatum(gatewaySnapshot ? (gatewaySnapshot.relayConnected ? "Conectado" : "Desconectado") : null)} />
          <MetricCard label="Plano de control" datum={controlDatum(controlSnapshot ? "Simulación disponible" : null)} />
        </div>
      </section>

      <section className={styles.section} aria-labelledby="capacity-heading">
        <SectionHeading eyebrow="02 / DEMANDA" id="capacity-heading" title="Espectadores y capacidad" />
        <div className={styles.metricGrid}>
          <MetricCard label="Espectadores autorizados" datum={controlDatum(controlSnapshot?.authorizedViewers ?? null)} format={formatInteger} />
          <MetricCard label="Sesiones activas Gateway" datum={gatewayDatum(gatewaySnapshot?.scheduler.activeSessions ?? null)} format={formatInteger} />
          <MetricCard label="Reservas vigentes" datum={controlDatum(capacityReserved)} format={formatInteger} />
          <MetricCard label="Capacidad disponible" datum={controlDatum(capacityAvailable)} format={formatInteger} />
          <MetricCard label="Capacidad reservada" datum={controlDatum(capacityReserved)} format={formatInteger} />
          <MetricCard label="Utilización" datum={controlDatum(utilization)} format={formatPercent} />
          <MetricCard label="Ancho de banda" datum={controlDatum(controlSnapshot?.egressMbps ?? null)} format={formatMbps} />
          <MetricCard label="Volumen distribuido" datum={gatewayDatum(gatewaySnapshot?.distributedBytes ?? null)} format={formatBytes} />
        </div>
        <p className={styles.explainer}>
          Autorizados, sesiones y reservas son conceptos distintos. La capacidad de Task 09 es una simulación de decisiones; no demuestra capacidad real de vídeo.
        </p>
      </section>

      <section className={styles.section} aria-labelledby="nodes-heading">
        <SectionHeading eyebrow="03 / TOPOLOGÍA" id="nodes-heading" title="Distribución lógica de nodos" />
        {controlSnapshot ? (
          <>
            <div className={styles.tableWrap} tabIndex={0} aria-label="Tabla desplazable de nodos simulados">
              <table>
                <caption>Proyección neutral del proveedor · simulación local Task 09</caption>
                <thead><tr><th>Rol</th><th>Proveedor</th><th>Región</th><th>Estado</th><th>Capacidad</th></tr></thead>
                <tbody>
                  {controlSnapshot.placements.map((node, index) => (
                    <tr key={`${node.role}-${node.provider}-${node.region}-${index}`}>
                      <td>{roleLabel(node.role)}</td><td>{node.provider}</td><td>{node.region}</td>
                      <td><span className={styles.textStatus}>LISTO · SIMULADO</span></td>
                      <td>{formatInteger(node.capacityViewers)} espectadores</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
            <p className={styles.tableMeta}>Simulación local · timestamp {formatTime(controlSnapshot.observedAt)} · edad no derivable del contrato · frescura desconocida.</p>
          </>
        ) : <EmptyState text="Distribución pendiente de integración; no hay nodos reales observables." />}
        <div className={styles.metricGrid}>
          <MetricCard label="Entrada de vídeo" datum={gatewayDatum(ingest?.items ?? null, ingest?.ageMs ?? null)} format={formatInteger} />
          <MetricCard label="Demux / empaquetado" datum={gatewayDatum(demux?.items ?? null, demux?.ageMs ?? null)} format={formatInteger} />
          <MetricCard label="Salida distribuida" datum={gatewayDatum(distribution?.items ?? null, distribution?.ageMs ?? null)} format={formatInteger} />
          <MetricCard label="Drain sin resolver" datum={controlDatum(controlSnapshot?.counters.unresolvedDrains ?? null)} format={formatInteger} />
        </div>
      </section>

      <section className={styles.section} aria-labelledby="quality-heading">
        <SectionHeading eyebrow="04 / CALIDAD" id="quality-heading" title="Calidad, latencia y presión" />
        <div className={styles.metricGrid}>
          <MetricCard label="Latencia p50" datum={gatewayDatum(gatewaySnapshot?.latency.p50Ms ?? null)} format={formatMs} />
          <MetricCard label="Latencia p95" datum={gatewayDatum(gatewaySnapshot?.latency.p95Ms ?? null)} format={formatMs} />
          <MetricCard label="Latencia p99" datum={gatewayDatum(gatewaySnapshot?.latency.p99Ms ?? null)} format={formatMs} />
          <MetricCard label="Muestras de latencia" datum={gatewayDatum(gatewaySnapshot?.latency.samples ?? null)} format={formatInteger} />
          <MetricCard label="Objetos en cola" datum={gatewayDatum(gatewaySnapshot?.scheduler.queuedObjects ?? null)} format={formatInteger} />
          <MetricCard label="Bytes en cola" datum={gatewayDatum(gatewaySnapshot?.scheduler.queuedBytes ?? null)} format={formatBytes} />
          <MetricCard label="Descartes" datum={gatewayDatum(gatewaySnapshot?.scheduler.dropped ?? null)} format={formatInteger} />
          <MetricCard label="Espectadores expulsados" datum={gatewayDatum(gatewaySnapshot?.scheduler.evicted ?? null)} format={formatInteger} />
        </div>
        <p className={styles.explainer}>Los percentiles reales corresponden exclusivamente a <code>ingest_to_publish</code>. Red, presentación y Glass-to-Glass no se infieren.</p>
      </section>

      <section className={styles.splitSection}>
        <div aria-labelledby="alerts-heading">
          <SectionHeading eyebrow="05 / ATENCIÓN" id="alerts-heading" title="Alertas" />
          <ul className={styles.alertList}>
            <AlertItem title="Capacidad" datum={controlSnapshot ? controlDatum(controlSnapshot.alerts.filter(({ code }) => code.includes("limit")).length) : pending<number>()} />
            <AlertItem title="Fallos" datum={controlSnapshot ? controlDatum(controlSnapshot.alerts.filter(({ code }) => code.includes("lifecycle") || code.includes("drain")).length) : pending<number>()} />
            <AlertItem title="Seguridad" datum={pending<number>()} />
          </ul>
        </div>
        <div aria-labelledby="cost-heading">
          <SectionHeading eyebrow="06 / COSTE" id="cost-heading" title="Costes" />
          <div className={styles.costGrid}>
            <MetricCard label="Coste medido" datum={controlDatum(controlSnapshot?.measuredCost.amount ?? null)} format={(value) => formatMoney(value, controlSnapshot?.measuredCost.currency)} />
            <MetricCard label="Coste proveedor estimado" datum={externalEstimate} format={(value) => formatMoney(value, controlSnapshot?.estimatedCost.currency)} />
          </div>
          <p className={styles.explainer}>El 0 medido sólo representa infraestructura remota creada por la simulación local: ninguna. La estimación cloud sigue no medida hasta integrar tarifas fechadas.</p>
        </div>
      </section>

      <section className={styles.section} aria-labelledby="activity-heading">
        <SectionHeading eyebrow="07 / HISTORIAL" id="activity-heading" title="Actividad reciente" />
        <ol className={styles.timeline}>
          <TimelineItem title="Snapshot Gateway" detail={gateway.snapshot ? `Revisión ${gateway.snapshot.revision}` : sourceReason(gateway.reason)} at={gateway.lastSuccessAt} />
          <TimelineItem title="Sustitución y recuperación" detail={controlSnapshot ? `${controlSnapshot.counters.replacements} sustitución; ${controlSnapshot.recovery.sessionsRecovered} sesiones recuperadas · simulación local` : sourceReason(control.reason)} at={control.lastSuccessAt} />
          <TimelineItem title="Drain de nodos" detail={controlSnapshot ? `${controlSnapshot.counters.unresolvedDrains} sin resolver · simulación local` : "Pendiente de integración"} at={control.lastSuccessAt} />
        </ol>
      </section>

      <section className={styles.section} aria-labelledby="controls-heading">
        <SectionHeading eyebrow="08 / FUTURO" id="controls-heading" title="Controles preparados y deshabilitados" />
        <p className={styles.controlsIntro}>Esta superficie no controla la plataforma. Una futura UI emitirá órdenes validadas al plano de control; nunca administrará proveedores directamente.</p>
        <div className={styles.controlsGrid}>
          {["Iniciar evento", "Finalizar evento", "Crear capacidad", "Escalar distribuidores", "Drenar nodo", "Sustituir nodo", "Activar redundancia", "Detener autoescalado", "Apagado de emergencia"].map((label) => (
            <div key={label}>
              <button type="button" disabled aria-describedby="control-requirements">{label}</button>
              <span>No disponible en modo read-only</span>
            </div>
          ))}
        </div>
        <p id="control-requirements" className={styles.requirements}>{CONTROL_REQUIREMENTS}</p>
      </section>
    </div>
  );
}

function reduceSource<T>(current: OperationsSourceState<T>, event: PollEvent<T>): OperationsSourceState<T> {
  if (event.type === "success") {
    const lastSuccessAt = new Date().toISOString();
    return { health: "available", snapshot: event.value, reason: "source-available", lastSuccessAt };
  }
  return {
    health: event.reason === "data-rejected" ? "rejected" : "lost",
    snapshot: current.snapshot,
    reason: event.reason,
    lastSuccessAt: current.lastSuccessAt,
  };
}

function SectionHeading({ eyebrow, id, title }: { eyebrow: string; id: string; title: string }) {
  return <div className={styles.sectionHeading}><p>{eyebrow}</p><h2 id={id}>{title}</h2></div>;
}

function MetricCard<T>({ label, datum: item, format = String }: { label: string; datum: Datum<T>; format?: (value: T) => string }) {
  return (
    <article className={styles.metricCard} data-status={item.status}>
      <p>{label}</p>
      <strong>{item.value === null ? statusLabel(item.status) : format(item.value)}</strong>
      <DatumMeta datum={item} />
    </article>
  );
}

function DatumMeta({ datum: item }: { datum: Datum<unknown> }) {
  return <small>{provenanceLabel(item.provenance)} · {statusLabel(item.status)} · {item.observedAt ? formatTime(item.observedAt) : "sin timestamp"} · {item.ageMs === null ? "edad desconocida" : formatAge(item.ageMs)} · {freshnessLabel(item.freshness)}</small>;
}

function SourceBadge({ label, state, provenance }: { label: string; state: OperationsSourceState<unknown> | null; provenance: "gateway-real" | "control-plane-simulation" | "cloud-future" }) {
  const text = state ? sourceReason(state.reason) : "Pendiente de integración";
  return <div className={styles.sourceBadge} data-health={state?.health ?? "future"}><span>{label}</span><strong>{text}</strong><small>{provenanceLabel(provenance)} · {state?.lastSuccessAt ? formatTime(state.lastSuccessAt) : "sin timestamp"}</small></div>;
}

function AlertItem({ title, datum: item }: { title: string; datum: Datum<number> }) {
  return <li><div><strong>{title}</strong><span>{item.value === null ? statusLabel(item.status) : `${item.value} alertas reportadas`}</span></div><DatumMeta datum={item} /></li>;
}

function TimelineItem({ title, detail, at }: { title: string; detail: string; at: string | null }) {
  return <li><time dateTime={at ?? undefined}>{at ? formatTime(at) : "Sin timestamp"}</time><div><strong>{title}</strong><p>{detail}</p></div></li>;
}

function EmptyState({ text }: { text: string }) { return <p className={styles.emptyState}>{text}</p>; }

function sourceReason(reason: OperationsSourceState<unknown>["reason"]) {
  return ({ loading: "Cargando", "source-available": "Disponible", "source-unreachable": "Fuente perdida", "data-rejected": "Dato rechazado", "not-configured": "Pendiente de integración" })[reason];
}
function provenanceLabel(value: Datum<unknown>["provenance"]) { return ({ "gateway-real": "Gateway real", "control-plane-simulation": "Simulación local", "cloud-future": "Cloud futuro" })[value]; }
function statusLabel(value: Datum<unknown>["status"]) { return ({ measured: "Medido", "local-simulation": "Simulación local", "not-measured": "No medido", "not-available": "No disponible", "pending-integration": "Pendiente de integración" })[value]; }
function freshnessLabel(value: Datum<unknown>["freshness"]) { return ({ fresh: "fresco", aging: "envejeciendo", stale: "antiguo", unknown: "frescura desconocida" })[value]; }
function roleLabel(value: string) { return ({ origin: "Origen", core: "Distribución core", regional: "Regional", "viewer-edge": "Borde espectador" } as Record<string, string>)[value] ?? value; }
function formatInteger(value: number) { return value.toLocaleString("es-ES"); }
function formatPercent(value: number) { return `${value.toLocaleString("es-ES", { maximumFractionDigits: 1 })} %`; }
function formatMbps(value: number) { return `${value.toLocaleString("es-ES")} Mbps`; }
function formatMs(value: number) { return `${value.toLocaleString("es-ES")} ms`; }
function formatBytes(value: number) { if (value < 1_000) return `${value} B`; if (value < 1_000_000) return `${(value / 1_000).toFixed(1)} kB`; if (value < 1_000_000_000) return `${(value / 1_000_000).toFixed(1)} MB`; return `${(value / 1_000_000_000).toFixed(2)} GB`; }
function formatMoney(value: number, currency = "EUR") { return new Intl.NumberFormat("es-ES", { style: "currency", currency }).format(value); }
function formatTime(value: string) { return new Intl.DateTimeFormat("es-ES", { dateStyle: "short", timeStyle: "medium" }).format(new Date(value)); }
function formatAge(value: number) { return value < 1_000 ? `${value} ms` : `${Math.round(value / 1_000)} s`; }
