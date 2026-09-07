#!/usr/bin/env node
// SPDX-FileCopyrightText: 2026 Teremoq contributors
// SPDX-License-Identifier: Apache-2.0

import crypto from "node:crypto";
import fs from "node:fs";
import https from "node:https";
import { ChannelRequestError, pinnedAgent, requestJson, scrub } from "../client/Lan-Interactive-Agent.mjs";

if (process.argv.length !== 4) throw new Error("certificate and private key paths are required");
const certificate = fs.readFileSync(process.argv[2]);
const privateKey = fs.readFileSync(process.argv[3]);
const fingerprint = crypto.createHash("sha256").update(new crypto.X509Certificate(certificate).raw).digest("hex");
for (const sensitive of [
  "-----BEGIN RSA PRIVATE KEY-----\nnot-a-key",
  "-----BEGIN EC PRIVATE KEY-----\nnot-a-key",
  "-----BEGIN OPENSSH PRIVATE KEY-----\nnot-a-key",
  "password=not-a-password",
  "api_key: not-a-token",
]) {
  const sanitized = scrub(`prefix ${sensitive}`);
  if (/not-a-(?:key|password|token)/.test(sanitized)) throw new Error("sensitive diagnostic was not scrubbed");
}
const server = https.createServer({ cert: certificate, key: privateKey }, (request, response) => {
  const chunks = [];
  request.on("data", (chunk) => chunks.push(chunk));
  request.on("end", () => {
    JSON.parse(Buffer.concat(chunks).toString("utf8"));
    const body = request.url === "/oversized" ? Buffer.alloc(40_000, 0x61)
      : request.url === "/invalid-json" ? Buffer.from("not-json", "utf8")
      : Buffer.from('{"accepted":true}', "utf8");
    const status = request.url === "/rejected" ? 403 : 200;
    response.writeHead(status, { "Content-Type": "application/json", "Content-Length": body.length });
    response.end(body);
  });
});
await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
const address = server.address();
try {
  const good = await requestJson(pinnedAgent(`https://127.0.0.1:${address.port}`, fingerprint), `https://127.0.0.1:${address.port}`, "/test", { test: true });
  if (good.accepted !== true) throw new Error("pinned request was not accepted");
  for (const [route, expectedFailure, expectedStatus] of [
    ["/oversized", "protocol", 0],
    ["/invalid-json", "protocol", 0],
    ["/rejected", "http", 403],
  ]) {
    let failure = null;
    try {
      await requestJson(pinnedAgent(`https://127.0.0.1:${address.port}`, fingerprint), `https://127.0.0.1:${address.port}`, route, { test: true });
    } catch (error) { failure = error; }
    if (!(failure instanceof ChannelRequestError) || failure.channelFailure !== expectedFailure ||
        failure.statusCode !== expectedStatus) {
      throw new Error(`channel response classification failed for ${route}`);
    }
  }
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
