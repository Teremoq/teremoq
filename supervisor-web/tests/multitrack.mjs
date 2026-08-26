import puppeteer from "puppeteer-core";

const browser = await puppeteer.connect({
  browserURL: process.env.CDP_URL ?? "http://127.0.0.1:19227",
});

try {
  const [page] = await browser.pages();
  const pageErrors = [];
  page.on("pageerror", (error) => pageErrors.push(error.message));
  await page.goto(process.env.TEREMOQ_SUPERVISOR_URL ?? "http://127.0.0.1:19090/", {
    waitUntil: "networkidle0",
  });
  await page.waitForFunction(
    () => document.querySelectorAll('[class*="trackMatrix"] > div[data-active="true"]').length === 4,
    { timeout: 15_000 },
  );
  const before = await trackRows(page);
  await wait(3_000);
  const after = await trackRows(page);
  const failures = [];
  for (const track of after) {
    const previous = before.find((candidate) => candidate.id === track.id);
    if (!previous || track.objects <= previous.objects) {
      failures.push(`Track ${track.id} no progresó en la matriz`);
    }
    if (!track.visible) failures.push(`Track ${track.id} no es visible en el viewport inicial`);
  }
  if (pageErrors.length > 0) failures.push(...pageErrors);
  const result = { before, after, pageErrors, failures };
  console.log(JSON.stringify(result, null, 2));
  if (failures.length > 0) throw new Error(failures.join("; "));
} finally {
  await browser.disconnect();
}

async function trackRows(page) {
  return page.evaluate(() =>
    [...document.querySelectorAll('[class*="trackMatrix"] > div')].map((row) => {
      const identity = row.querySelector('[class*="trackIdentity"]')?.textContent ?? "";
      const id = Number(identity.match(/^TRACK (\d+)/)?.[1] ?? -1);
      const objectsLabel = [...row.querySelectorAll('[class*="trackCardFooter"] span')]
        .at(-1)
        ?.textContent ?? "";
      const objects = Number(objectsLabel.replaceAll(".", "").replace(" OBJ", ""));
      const bounds = row.getBoundingClientRect();
      const visible =
        bounds.width > 0 &&
        bounds.height > 0 &&
        bounds.top >= 0 &&
        bounds.bottom <= window.innerHeight;
      return { id, objects, visible, text: row.textContent?.trim() ?? "" };
    }),
  );
}

function wait(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}
