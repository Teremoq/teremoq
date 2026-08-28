import { TeremoqPlayer } from "@/components/teremoq-player";
import Link from "next/link";
import styles from "./page.module.css";

export default function Home() {
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
          <span className={styles.environment}>LAB LOOPBACK</span>
          <Link className={styles.operationsLink} href="/operations">
            OPERACIONES
          </Link>
        </div>
      </header>

      <section className={styles.intro}>
        <p className={styles.eyebrow}>SUPERVISOR / SIGNAL COMPARISON</p>
        <h1>Entrada y salida, una sola vista.</h1>
        <p className={styles.lede}>
          Observador SRT independiente frente al receptor MoQT/WebCodecs. Dos
          caminos aislados, sin transcoding ni métricas de latencia inventadas.
        </p>
      </section>

      <TeremoqPlayer />

      <footer className={styles.footer}>
        <span>TEREMOQ POC</span>
        <span>G2G verificable en el fixture visual · fuentes broadcast requieren PTP/LTC.</span>
      </footer>
    </main>
  );
}
