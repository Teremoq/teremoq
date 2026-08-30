import type { NextRequest } from "next/server";
import { NextResponse } from "next/server";
import {
  isLanLabEnabled,
  lanLabRequestDecision,
} from "./lib/lan-lab/config";

export function proxy(request: NextRequest) {
  if (!isLanLabEnabled(process.env)) return NextResponse.next();

  const decision = lanLabRequestDecision(
    request.headers.get("host"),
    request.nextUrl.pathname,
    request.method,
  );
  if (decision === "allow") return NextResponse.next();
  if (decision === "method-not-allowed") {
    return safeResponse(405, { Allow: "GET, HEAD" });
  }
  return safeResponse(decision === "misdirected" ? 421 : 404);
}

function safeResponse(status: number, extraHeaders: Record<string, string> = {}) {
  return new NextResponse(null, {
    status,
    headers: {
      "Cache-Control": "no-store",
      "Content-Security-Policy": "default-src 'none'; frame-ancestors 'none'",
      "Referrer-Policy": "no-referrer",
      "X-Content-Type-Options": "nosniff",
      ...extraHeaders,
    },
  });
}
