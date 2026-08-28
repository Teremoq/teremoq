import { readFile, stat } from "node:fs/promises";
import path from "node:path";
import { parseTask09Report } from "../../../../lib/operations/control-plane-adapter";

export const dynamic = "force-dynamic";
export const runtime = "nodejs";

const MAX_FIXTURE_BYTES = 2 * 1024 * 1024;
const TASK_09_REPORT = path.resolve(
  process.cwd(),
  "../control-plane/reports/task-09/milestone-100.json",
);

export async function GET() {
  if (process.env.TEREMOQ_OPERATIONS_LOCAL_SIMULATION !== "task-09") {
    return safeJson({ status: "not-configured" }, 503);
  }
  try {
    const metadata = await stat(TASK_09_REPORT);
    if (!metadata.isFile() || metadata.size > MAX_FIXTURE_BYTES) {
      return safeJson({ status: "data-rejected" }, 422);
    }
    const body = await readFile(TASK_09_REPORT, "utf8");
    const report: unknown = JSON.parse(body);
    const projection = parseTask09Report(report, metadata.mtime);
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
