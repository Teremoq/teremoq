import { describe, expect, it } from "vitest";
import {
  VISUAL_TIMECODE,
  decodeVisualTimecodeRow,
  visualTimecodeLatencyMs,
  visualTimecodeRegion,
} from "./visual-timecode";

describe("timecode visual del fixture", () => {
  it("mantiene la fila de muestreo a 27 px del borde inferior", () => {
    expect(visualTimecodeRegion(1280, 720).y).toBe(693);
    expect(visualTimecodeRegion(640, 360).y).toBe(333);
    expect(visualTimecodeRegion(640, 360).stride).toBe(7);
  });
  it("decodifica Gray de 38 bits y verifica el checksum", () => {
    const centiseconds = 178_000_123_456;
    const row = encodeRow(centiseconds);

    expect(decodeVisualTimecodeRow(row)).toBe(centiseconds * 10);
  });

  it("rechaza preámbulo o checksum corruptos", () => {
    const row = encodeRow(178_000_123_456);
    paintBit(row, 0, 0);
    expect(decodeVisualTimecodeRow(row)).toBeNull();

    const checksumRow = encodeRow(178_000_123_456);
    const checksumStart = VISUAL_TIMECODE.preamble.length + VISUAL_TIMECODE.timestampBits;
    paintBit(checksumRow, checksumStart, 1 - readBit(checksumRow, checksumStart));
    expect(decodeVisualTimecodeRow(checksumRow)).toBeNull();
  });

  it("solo acepta timestamps recientes y no futuros", () => {
    expect(visualTimecodeLatencyMs(9_500, 10_000)).toBe(500);
    expect(visualTimecodeLatencyMs(10_001, 10_000)).toBeNull();
    expect(visualTimecodeLatencyMs(0, 10_001)).toBeNull();
  });
});

function encodeRow(centiseconds: number) {
  const { width } = visualTimecodeRegion();
  const row = new Uint8ClampedArray(width * 4);
  const binary = Array.from(
    { length: VISUAL_TIMECODE.timestampBits + 1 },
    (_, index) => Math.floor(centiseconds / 2 ** index) % 2,
  );
  const gray = Array.from(
    { length: VISUAL_TIMECODE.timestampBits },
    (_, index) => (binary[index] ?? 0) === (binary[index + 1] ?? 0) ? 0 : 1,
  );
  const checksum = Array.from(
    { length: VISUAL_TIMECODE.checksumBits },
    (_, index) => Math.floor((centiseconds % 256) / 2 ** index) % 2,
  );
  const bits = [...VISUAL_TIMECODE.preamble, ...gray, ...checksum];
  bits.forEach((bit, index) => paintBit(row, index, bit));
  return row;
}

function paintBit(row: Uint8ClampedArray, index: number, bit: number) {
  const offset = index * VISUAL_TIMECODE.stride * 4;
  row[offset] = bit * 255;
  row[offset + 1] = bit * 255;
  row[offset + 2] = bit * 255;
  row[offset + 3] = 255;
}

function readBit(row: Uint8ClampedArray, index: number) {
  return row[index * VISUAL_TIMECODE.stride * 4] >= 128 ? 1 : 0;
}
