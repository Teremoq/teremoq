import { LanLoadGeneratorPanel } from "@/components/lan-load-generator";
import {
  configuredLanLoadLevel,
  isLanLabEnabled,
  resolvePlayerDeployment,
} from "@/lib/lan-lab/config";
import Link from "next/link";
import { connection } from "next/server";
import { notFound } from "next/navigation";
import styles from "./page.module.css";

export default function LanLoadPage() {
  if (!isLanLabEnabled(process.env)) notFound();
  return <LanLoadRuntime />;
}

async function LanLoadRuntime() {
  await connection();
  const deployment = resolvePlayerDeployment(process.env);
  const initialLevel = configuredLanLoadLevel(process.env);

  return (
    <main className={styles.shell}>
      <header className={styles.header}>
        <div>
          <p className={styles.brand}>TEREMOQ</p>
          <span>LAN LAB / NO PRODUCCIÓN</span>
        </div>
        <Link href="/">VOLVER AL PLAYER REAL</Link>
      </header>

      <section className={styles.intro} aria-labelledby="page-heading">
        <p>PRUEBA PROGRESIVA · 5 / 10 / 25</p>
        <h1 id="page-heading">Clientes ligeros, observación real.</h1>
        <p>
          Esta ruta existe únicamente en el paquete LAN local. Las sesiones comparten
          el fingerprint TLS y el namespace validados del player, pero no crean canvas,
          VideoDecoder ni métricas derivadas de transporte.
        </p>
      </section>

      <LanLoadGeneratorPanel deployment={deployment} initialLevel={initialLevel} />

      <footer className={styles.footer}>
        Sólo localhost · GET/HEAD · máximo 25 clientes · cierre y reintentos acotados
      </footer>
    </main>
  );
}
