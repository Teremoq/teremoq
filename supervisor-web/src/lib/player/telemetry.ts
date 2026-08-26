import { MoqProtocolError } from "../moqt/binary";

const MAX_TELEMETRY_BYTES = 4 * 1024;

export type VehicleTelemetry = {
  sequence: number;
  vehicle: string;
  latitude: number;
  longitude: number;
  speedKph: number;
};

export function parseVehicleTelemetry(payload: Uint8Array): VehicleTelemetry {
  if (payload.byteLength === 0 || payload.byteLength > MAX_TELEMETRY_BYTES) {
    throw new MoqProtocolError("telemetría vacía o fuera de límite");
  }
  let value: unknown;
  try {
    const text = new TextDecoder("utf-8", { fatal: true }).decode(payload).trim();
    value = JSON.parse(text) as unknown;
  } catch (cause: unknown) {
    throw new MoqProtocolError(`telemetría JSON inválida: ${toMessage(cause)}`);
  }
  if (
    !isRecord(value) ||
    !isSafeInteger(value.sequence, 0, Number.MAX_SAFE_INTEGER) ||
    typeof value.vehicle !== "string" ||
    value.vehicle.length === 0 ||
    value.vehicle.length > 64 ||
    !isSafeInteger(value.lat_e7, -900_000_000, 900_000_000) ||
    !isSafeInteger(value.lon_e7, -1_800_000_000, 1_800_000_000) ||
    typeof value.speed_kph !== "number" ||
    !Number.isFinite(value.speed_kph) ||
    value.speed_kph < 0 ||
    value.speed_kph > 500
  ) {
    throw new MoqProtocolError("campos de telemetría inválidos");
  }
  return {
    sequence: value.sequence,
    vehicle: value.vehicle,
    latitude: value.lat_e7 / 10_000_000,
    longitude: value.lon_e7 / 10_000_000,
    speedKph: value.speed_kph,
  };
}

function isSafeInteger(value: unknown, minimum: number, maximum: number): value is number {
  return Number.isSafeInteger(value) && Number(value) >= minimum && Number(value) <= maximum;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

function toMessage(cause: unknown) {
  return cause instanceof Error ? cause.message : String(cause);
}
