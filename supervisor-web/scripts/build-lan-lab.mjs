import { spawn } from "node:child_process";
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);
const nextCli = require.resolve("next/dist/bin/next");
const child = spawn(process.execPath, [nextCli, "build"], {
  stdio: "inherit",
  env: { ...process.env, TEREMOQ_LAN_LAB: "1" },
});

const forwardSignal = (signal) => {
  if (!child.killed) child.kill(signal);
};
const forwardInterrupt = () => forwardSignal("SIGINT");
const forwardTermination = () => forwardSignal("SIGTERM");
process.once("SIGINT", forwardInterrupt);
process.once("SIGTERM", forwardTermination);
child.once("error", () => {
  process.stderr.write("No se pudo construir el paquete LAN local.\n");
  process.exitCode = 1;
});
child.once("exit", (code) => {
  process.removeListener("SIGINT", forwardInterrupt);
  process.removeListener("SIGTERM", forwardTermination);
  process.exitCode = code ?? 1;
});
