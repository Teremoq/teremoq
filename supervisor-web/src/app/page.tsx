import { TeremoqPlayer } from "@/components/teremoq-player";
import {
  isLanLabEnabled,
  resolvePlayerDeployment,
  type PlayerDeployment,
} from "@/lib/lan-lab/config";
import Link from "next/link";
import { connection } from "next/server";
import styles from "./page.module.css";

export default function Home() {
  if (isLanLabEnabled(process.env)) return <LanLabHome />;
  return <HomeContent deployment={resolvePlayerDeployment({})} />;
}

async function LanLabHome() {
  await connection();
  return <HomeContent deployment={resolvePlayerDeployment(process.env)} />;
}

function HomeContent({ deployment }: Readonly<{ deployment: PlayerDeployment }>) {
  const lanLab = deployment.mode === "lan-lab";

  return (
    <main className={styles.shell}>
      <header className={styles.header}>
        <div className={styles.brand}>
          <span className={styles.mark} aria-hidden="true" />
          <div>
            <p>TEREMOQ</p>
            <span>EDGE CONTROL</span>
          </div>
        </div>
        <div className={styles.context}>
          <span>ZERO-LATENCY PLAYER</span>
          <span className={styles.environment} data-lan={lanLab}>
            {deployment.environmentLabel}
          </span>
          {deployment.operationsAvailable && (
            <Link className={styles.operationsLink} href="/operations">
              OPERACIONES
            </Link>
          )}
        </div>
      </header>

      <section className={styles.intro}>
        <p className={styles.eyebrow}>
          {lanLab ? "PLAYER REMOTO / LABORATORIO LAN" : "SUPERVISOR / SIGNAL COMPARISON"}
        </p>
        <h1>{lanLab ? "Salida MoQT en el cliente LAN." : "Entrada y salida, una sola vista."}</h1>
        <p className={styles.lede}>
          {lanLab
            ? "Paquete local de prueba para WebTransport y WebCodecs. No expone operaciones ni consulta el supervisor del Gateway; las métricas ausentes permanecen no medidas."
            : "Observador SRT independiente frente al receptor MoQT/WebCodecs. Dos caminos aislados, sin transcoding ni métricas de latencia inventadas."}
        </p>
      </section>

      <TeremoqPlayer deployment={deployment} />

      <footer className={styles.footer}>
        <span>{lanLab ? "TEREMOQ LAN LAB · NO PRODUCCIÓN" : "TEREMOQ POC"}</span>
        <span>
          {lanLab
            ? "Configuración local inmutable · sin dashboard ni plano de control."
            : "G2G verificable en el fixture visual · fuentes broadcast requieren PTP/LTC."}
        </span>
      </footer>
    </main>
  );
}
