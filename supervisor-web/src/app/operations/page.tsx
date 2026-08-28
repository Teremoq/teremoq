import type { Metadata } from "next";
import Link from "next/link";
import { OperationsDashboard } from "../../components/operations-dashboard";
import styles from "./page.module.css";

export const metadata: Metadata = {
  title: "Teremoq · Centro de Operaciones",
  description: "Vista read-only del estado operativo de Teremoq",
};

export default function OperationsPage() {
  return (
    <main className={styles.shell}>
      <header className={styles.header}>
        <div className={styles.brand}><span className={styles.mark} aria-hidden="true" /><div><p>TEREMOQ</p><span>CENTRAL OPERATIONS</span></div></div>
        <nav aria-label="Navegación principal"><Link href="/">Supervisor de vídeo</Link><Link href="/operations" aria-current="page">Operaciones</Link></nav>
      </header>
      <section className={styles.intro} aria-labelledby="operations-title">
        <div><p>OPERACIONES / SOLO LECTURA</p><h1 id="operations-title">El directo, explicado con evidencia.</h1></div>
        <p>Una vista central para entender demanda, capacidad, distribución y salud sin confundir datos reales, simulaciones locales ni integraciones futuras.</p>
      </section>
      <OperationsDashboard />
      <footer className={styles.footer}><span>TEREMOQ POC · READ-ONLY</span><span>Los controles operativos permanecen deshabilitados.</span></footer>
    </main>
  );
}
