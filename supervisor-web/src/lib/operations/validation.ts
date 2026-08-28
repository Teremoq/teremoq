export class OperationsDataError extends Error {
  readonly code:
    | "schema-incompatible"
    | "payload-excessive"
    | "data-invalid"
    | "data-inconsistent";

  constructor(code: OperationsDataError["code"]) {
    super(code);
    this.name = "OperationsDataError";
    this.code = code;
  }
}

export const MAX_SAFE = Number.MAX_SAFE_INTEGER;

export function record(value: unknown): Record<string, unknown> {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    throw new OperationsDataError("data-invalid");
  }
  return value as Record<string, unknown>;
}

export function exact(
  value: unknown,
  required: readonly string[],
  optional: readonly string[] = [],
): Record<string, unknown> {
  const candidate = record(value);
  const allowed = new Set([...required, ...optional]);
  if (
    required.some((key) => !(key in candidate)) ||
    Object.keys(candidate).some((key) => !allowed.has(key))
  ) {
    throw new OperationsDataError("data-invalid");
  }
  return candidate;
}

export function integer(value: unknown, maximum = MAX_SAFE): number {
  if (!Number.isSafeInteger(value) || (value as number) < 0 || (value as number) > maximum) {
    throw new OperationsDataError("data-invalid");
  }
  return value as number;
}

export function finite(value: unknown, maximum = MAX_SAFE): number {
  if (typeof value !== "number" || !Number.isFinite(value) || value < 0 || value > maximum) {
    throw new OperationsDataError("data-invalid");
  }
  return value;
}

export function boundedString(value: unknown, maximum: number): string {
  if (typeof value !== "string" || value.length < 1 || value.length > maximum) {
    throw new OperationsDataError("data-invalid");
  }
  return value;
}

export function nullableInteger(value: unknown, maximum = MAX_SAFE): number | null {
  return value === null ? null : integer(value, maximum);
}

export function enumeration<T extends string>(value: unknown, allowed: readonly T[]): T {
  if (typeof value !== "string" || !allowed.includes(value as T)) {
    throw new OperationsDataError("data-invalid");
  }
  return value as T;
}

export function array(value: unknown, maximum: number): unknown[] {
  if (!Array.isArray(value) || value.length > maximum) {
    throw new OperationsDataError("payload-excessive");
  }
  return value;
}

export function assertSchemaOne(value: unknown) {
  if (value !== 1) throw new OperationsDataError("schema-incompatible");
}

export function assertIsoTimestamp(value: unknown): string {
  const timestamp = boundedString(value, 64);
  const parsed = Date.parse(timestamp);
  if (!Number.isFinite(parsed) || new Date(parsed).toISOString() !== timestamp) {
    throw new OperationsDataError("data-invalid");
  }
  return timestamp;
}
