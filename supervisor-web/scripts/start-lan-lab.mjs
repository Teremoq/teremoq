import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";

const scriptDirectory = dirname(fileURLToPath(import.meta.url));
const packagedServer = resolve(scriptDirectory, "server.js");
const localBuildServer = resolve(scriptDirectory, "..", ".next", "standalone", "server.js");
const server = existsSync(packagedServer) ? packagedServer : localBuildServer;
if (!existsSync(server)) {
  process.stderr.write("Falta el build LAN standalone. Ejecuta npm run build:lan.\n");
  process.exit(1);
}
const child = spawn(
  process.execPath,
  [server],
  {
    stdio: "inherit",
    cwd: dirname(server),
    env: {
      ...process.env,
      HOSTNAME: "127.0.0.1",
      TEREMOQ_LAN_LAB: "1",
    },
  },
);

const forwardSignal = (signal) => {
  if (!child.killed) child.kill(signal);
};
const forwardInterrupt = () => forwardSignal("SIGINT");
const forwardTermination = () => forwardSignal("SIGTERM");
process.once("SIGINT", forwardInterrupt);
process.once("SIGTERM", forwardTermination);
child.once("error", () => {
  process.stderr.write("No se pudo iniciar el paquete LAN local.\n");
  process.exitCode = 1;
});
child.once("exit", (code) => {
  process.removeListener("SIGINT", forwardInterrupt);
  process.removeListener("SIGTERM", forwardTermination);
  process.exitCode = code ?? 1;
});
