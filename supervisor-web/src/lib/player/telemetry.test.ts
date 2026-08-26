import { describe, expect, it } from "vitest";
import { parseVehicleTelemetry } from "./telemetry";

describe("telemetría MoQT", () => {
  it("valida y normaliza el mensaje del vehículo", () => {
    const payload = new TextEncoder().encode(
      '{"sequence":42,"vehicle":"car-01","lat_e7":404168123,"lon_e7":-37037877,"speed_kph":173}',
    );
    expect(parseVehicleTelemetry(payload)).toEqual({
      sequence: 42,
      vehicle: "car-01",
      latitude: 40.4168123,
      longitude: -3.7037877,
      speedKph: 173,
    });
  });

  it("acepta el padding del transporte y rechaza coordenadas imposibles", () => {
    const padded = new TextEncoder().encode(
      '{"sequence":1,"vehicle":"car-01","lat_e7":404168000,"lon_e7":-37038000,"speed_kph":90}   \n',
    );
    expect(parseVehicleTelemetry(padded).speedKph).toBe(90);
    const invalid = new TextEncoder().encode(
      '{"sequence":1,"vehicle":"car-01","lat_e7":904168000,"lon_e7":-37038000,"speed_kph":90}',
    );
    expect(() => parseVehicleTelemetry(invalid)).toThrow(/campos/);
  });
});
