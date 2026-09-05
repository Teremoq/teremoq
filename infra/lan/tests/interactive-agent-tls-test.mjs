#!/usr/bin/env node
// SPDX-FileCopyrightText: 2026 Teremoq contributors
// SPDX-License-Identifier: Apache-2.0

import crypto from "node:crypto";
import fs from "node:fs";
import https from "node:https";
import { pinnedAgent, requestJson, scrub } from "../client/Lan-Interactive-Agent.mjs";

if (process.argv.length !== 4) throw new Error("certificate and private key paths are required");
const certificate = fs.readFileSync(process.argv[2]);
const privateKey = fs.readFileSync(process.argv[3]);
const fingerprint = crypto.createHash("sha256").update(new crypto.X509Certificate(certificate).raw).digest("hex");
const server = https.createServer({ cert: certificate, key: privateKey }, (request, response) => {
  const chunks = [];
  request.on("data", (chunk) => chunks.push(chunk));
  request.on("end", () => {
    JSON.parse(Buffer.concat(chunks).toString("utf8"));
    const body = Buffer.from('{"accepted":true}', "utf8");
    response.writeHead(200, { "Content-Type": "application/json", "Content-Length": body.length });
    response.end(body);
  });
});
await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
const address = server.address();
try {
  const good = await requestJson(pinnedAgent(`https://127.0.0.1:${address.port}`, fingerprint), `https://127.0.0.1:${address.port}`, "/test", { test: true });
  if (good.accepted !== true) throw new Error("pinned request was not accepted");
  let rejected = false;
  try {
    await requestJson(pinnedAgent(`https://127.0.0.1:${address.port}`, "0".repeat(64)), `https://127.0.0.1:${address.port}`, "/test", { test: true });
  } catch (error) {
    scrub(error.message);
    rejected = true;
  }
  if (!rejected) throw new Error("wrong fingerprint was not rejected");
} finally {
  await new Promise((resolve) => server.close(resolve));
}
console.log("lan-interactive-agent-tls-test: PASS");
