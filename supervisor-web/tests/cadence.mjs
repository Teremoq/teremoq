import puppeteer from "puppeteer-core";

const videoTrack = boundedOption("TEREMOQ_VIDEO_TRACK", "--track", 0, 0, 1);
const durationMs = boundedOption(
  "TEREMOQ_CADENCE_DURATION_MS",
  "--duration-ms",
  20_000,
  5_000,
  120_000,
);
const minimumFps = boundedOption("TEREMOQ_CADENCE_MIN_FPS", "--min-fps", 25, 1, 60);
const maximumStallMs = boundedEnvironmentNumber(
  "TEREMOQ_CADENCE_MAX_STALL_MS",
  500,
  100,
  5_000,
);
const maximumClientDropRatio = boundedEnvironmentNumber(
  "TEREMOQ_CADENCE_MAX_CLIENT_DROP_RATIO",
  0.05,
  0,
  1,
);
const maximumDrawIntervalP95Ms = boundedOption(
  "TEREMOQ_CADENCE_MAX_DRAW_P95_MS",
  "--max-draw-p95-ms",
  80,
  34,
  500,
);
const browser = await puppeteer.connect({
  browserURL: process.env.CDP_URL ?? "http://127.0.0.1:19227",
});

try {
  const [page] = await browser.pages();
  const pageErrors = [];
  page.on("pageerror", (error) => pageErrors.push(error.message));
  await page.evaluateOnNewDocument(() => {
    globalThis.__TEREMOQ_DRAW_TIMES = [];
    const drawImage = CanvasRenderingContext2D.prototype.drawImage;
    CanvasRenderingContext2D.prototype.drawImage = function (...args) {
      if (this.canvas.isConnected) globalThis.__TEREMOQ_DRAW_TIMES.push(performance.now());
      return drawImage.apply(this, args);
    };
  });
  await page.goto(process.env.TEREMOQ_SUPERVISOR_URL ?? "http://127.0.0.1:19090/", {
    waitUntil: "networkidle0",
  });
  await page.waitForFunction(() => document.body.innerText.includes("DISPONIBLE"), {
    timeout: 10_000,
  });
  await page.waitForFunction(() => {
    const frame = document.querySelector('iframe[title="Señal SRT de entrada"]');
    const video = frame?.contentDocument?.querySelector("video");
    return Boolean(
      video &&
        !video.paused &&
        video.readyState >= HTMLMediaElement.HAVE_CURRENT_DATA &&
        video.currentTime > 0,
    );
  }, { timeout: 20_000 });
  await page.locator(`button[data-track="${videoTrack}"]`).click();
  await page.locator('button[data-testid="connect-player"]').click();
  await page.waitForFunction(() => document.body.innerText.includes("Reproduciendo"), {
    timeout: 20_000,
  });
  await page.waitForFunction(
    () => document.querySelector('[class*="telemetryPanel"]')?.getAttribute("data-live") === "true",
    { timeout: 10_000 },
  );
  await wait(2_000);
  const telemetrySequenceBefore = await telemetrySequence(page);
  const clientDropsBefore = await clientDropCount(page);

  const samples = [];
  const sampleIntervalMs = 100;
  const sampleCount = Math.ceil(durationMs / sampleIntervalMs);
  for (let index = 0; index <= sampleCount; index += 1) {
    samples.push(await readFrameSample(page));
    if (index < sampleCount) await wait(sampleIntervalMs);
  }

  const frames = samples.at(-1).frames - samples[0].frames;
  const measuredMs = samples.at(-1).at - samples[0].at;
  const fps = frames / (measuredMs / 1_000);
  const longestStallMs = longestStall(samples);
  const drawTimes = await page.evaluate(() => globalThis.__TEREMOQ_DRAW_TIMES ?? []);
  const clientDropsAfter = await clientDropCount(page);
  const clientDrops = Math.max(0, clientDropsAfter - clientDropsBefore);
  const drawIntervals = drawTimes.slice(1).map((at, index) => at - drawTimes[index]);
  const drawIntervalP95Ms = percentile(drawIntervals, 0.95);
  const clientDropRatio = clientDrops / Math.max(1, drawTimes.length + clientDrops);
  const telemetrySequenceAfter = await telemetrySequence(page);
  const result = {
    videoTrack,
    measuredMs,
    frames,
    fps: Number(fps.toFixed(2)),
    longestStallMs: Number(longestStallMs.toFixed(1)),
    minimumFps,
    maximumStallMs,
    drawIntervalP50Ms: percentile(drawIntervals, 0.5),
    drawIntervalP95Ms,
    maximumDrawIntervalP95Ms,
    burstIntervals: drawIntervals.filter((interval) => interval < 10).length,
    stalledIntervals: drawIntervals.filter((interval) => interval > 100).length,
    canvasDraws: drawTimes.length,
    clientDrops,
    clientDropsBefore,
    clientDropsAfter,
    clientDropRatio: Number(clientDropRatio.toFixed(4)),
    maximumClientDropRatio,
    telemetrySequenceBefore,
    telemetrySequenceAfter,
    pageErrors,
  };
  console.log(JSON.stringify(result, null, 2));

  if (pageErrors.length > 0) throw new Error(`errores de página: ${pageErrors.join("; ")}`);
  if (fps < minimumFps) {
    throw new Error(`cadencia insuficiente: ${fps.toFixed(2)} fps < ${minimumFps} fps`);
  }
  if (longestStallMs > maximumStallMs) {
    throw new Error(`pausa excesiva: ${longestStallMs.toFixed(1)} ms > ${maximumStallMs} ms`);
  }
  if (drawIntervalP95Ms === null || drawIntervalP95Ms > maximumDrawIntervalP95Ms) {
    throw new Error(
      `presentación irregular: p95 ${drawIntervalP95Ms ?? "sin datos"} ms > ${maximumDrawIntervalP95Ms} ms`,
    );
  }
  if (clientDropRatio > maximumClientDropRatio) {
    throw new Error(
      `demasiados descartes cliente: ${(clientDropRatio * 100).toFixed(2)}% > ${(maximumClientDropRatio * 100).toFixed(2)}%`,
    );
  }
  if (telemetrySequenceAfter <= telemetrySequenceBefore) {
    throw new Error("Track 3 no progresó durante la prueba de cadencia");
  }
} finally {
  await browser.disconnect();
}

function percentile(values, quantile) {
  if (values.length === 0) return null;
  const sorted = [...values].sort((left, right) => left - right);
  return Number(sorted[Math.floor((sorted.length - 1) * quantile)].toFixed(1));
}

async function readFrameSample(page) {
  return page.evaluate(() => {
    const label = [...document.querySelectorAll("span")].find(
      (node) => node.textContent?.trim().toUpperCase() === "FRAMES CANVAS",
    );
    const text = label?.parentElement?.querySelector("strong")?.textContent ?? "0";
    return {
      at: performance.now(),
      frames: Number(text.replaceAll(".", "")),
    };
  });
}

function longestStall(samples) {
  let longestMs = 0;
  let lastAdvanceAt = samples[0].at;
  let previousFrames = samples[0].frames;
  for (const sample of samples.slice(1)) {
    if (sample.frames <= previousFrames) continue;
    longestMs = Math.max(longestMs, sample.at - lastAdvanceAt);
    lastAdvanceAt = sample.at;
    previousFrames = sample.frames;
  }
  return Math.max(longestMs, samples.at(-1).at - lastAdvanceAt);
}

async function telemetrySequence(page) {
  return page.evaluate(() => {
    const panel = document.querySelector('[class*="telemetryPanel"]');
    const label = [...(panel?.querySelectorAll("span") ?? [])].find(
      (node) => node.textContent?.trim().toUpperCase() === "SECUENCIA",
    );
    return Number(label?.parentElement?.querySelector("strong")?.textContent?.replaceAll(".", "") ?? -1);
  });
}

async function clientDropCount(page) {
  return page.evaluate(() => {
    const label = [...document.querySelectorAll("span")].find(
      (node) => node.textContent?.trim().toUpperCase() === "DESCARTES CLIENTE",
    );
    return Number(label?.parentElement?.querySelector("strong")?.textContent?.replaceAll(".", "") ?? 0);
  });
}

function boundedEnvironmentNumber(name, fallback, minimum, maximum) {
  const value = Number(process.env[name] ?? fallback);
  if (!Number.isFinite(value) || value < minimum || value > maximum) {
    throw new Error(`${name} debe estar entre ${minimum} y ${maximum}`);
  }
  return value;
}

function boundedOption(environmentName, argumentName, fallback, minimum, maximum) {
  const argumentIndex = process.argv.indexOf(argumentName);
  const argumentValue = argumentIndex >= 0 ? process.argv[argumentIndex + 1] : undefined;
  const value = Number(argumentValue ?? process.env[environmentName] ?? fallback);
  if (!Number.isFinite(value) || value < minimum || value > maximum) {
    throw new Error(`${argumentName} debe estar entre ${minimum} y ${maximum}`);
  }
  return value;
}

function wait(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}
