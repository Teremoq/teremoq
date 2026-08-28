import { createHash } from "node:crypto";
import path from "node:path";
import { readUtf8FileLimited } from "../../../../lib/operations/bounded-file";
import { parseTask09Report } from "../../../../lib/operations/control-plane-adapter";

export const dynamic = "force-dynamic";
export const runtime = "nodejs";

const MAX_FIXTURE_BYTES = 2 * 1024 * 1024;
const TASK_09_RAW_SHA256 = "99ccc74f6e8ceeeaaf86b18aa16a9610b7f6185feec8037a94e41b8c4bf1a77f";
const TASK_09_REPORT = path.resolve(
  process.cwd(),
  "../control-plane/reports/task-09/milestone-100.json",
);

export async function GET() {
  if (process.env.TEREMOQ_OPERATIONS_LOCAL_SIMULATION !== "task-09") {
    return safeJson({ status: "not-configured" }, 503);
  }
  try {
    const fixture = await readUtf8FileLimited(TASK_09_REPORT, MAX_FIXTURE_BYTES);
    if (createHash("sha256").update(fixture.text, "utf8").digest("hex") !== TASK_09_RAW_SHA256) {
      return safeJson({ status: "data-rejected" }, 422);
    }
    const report: unknown = JSON.parse(fixture.text);
    const projection = parseTask09Report(report, fixture.modifiedAt);
    return safeJson(projection, 200);
  } catch {
    return safeJson({ status: "data-rejected" }, 422);
  }
}

function safeJson(value: unknown, status: number) {
  return Response.json(value, {
    status,
    headers: {
      "Cache-Control": "no-store",
      "Content-Security-Policy": "default-src 'none'; frame-ancestors 'none'",
      "X-Content-Type-Options": "nosniff",
    },
  });
}
