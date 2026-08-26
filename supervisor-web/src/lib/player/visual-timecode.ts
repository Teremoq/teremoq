export const VISUAL_TIMECODE = {
  x: 24,
  y: 684,
  blockWidth: 12,
  blockHeight: 18,
  stride: 14,
  preamble: [1, 0, 1, 1, 0, 1, 0, 0] as const,
  timestampBits: 38,
  checksumBits: 8,
  unitsPerSecond: 100,
} as const;

const TOTAL_BITS =
  VISUAL_TIMECODE.preamble.length +
  VISUAL_TIMECODE.timestampBits +
  VISUAL_TIMECODE.checksumBits;
const SAMPLE_X = VISUAL_TIMECODE.x + Math.floor(VISUAL_TIMECODE.blockWidth / 2);
const SAMPLE_Y = VISUAL_TIMECODE.y + Math.floor(VISUAL_TIMECODE.blockHeight / 2);
const MAX_TIMECODE_AGE_MS = 10_000;

export type VisualTimecodeRegion = {
  x: number;
  y: number;
  width: number;
  stride: number;
};

export function visualTimecodeRegion(frameWidth = 1280, frameHeight = 720): VisualTimecodeRegion {
  const compact = frameWidth < 800;
  const stride = compact ? 7 : VISUAL_TIMECODE.stride;
  return {
    x: compact ? 15 : SAMPLE_X,
    y: frameHeight - (720 - SAMPLE_Y),
    width: (TOTAL_BITS - 1) * stride + 1,
    stride,
  };
}

export function readVisualTimecode(context: CanvasRenderingContext2D) {
  const { x, y, width, stride } = visualTimecodeRegion(
    context.canvas.width,
    context.canvas.height,
  );
  if (context.canvas.width < x + width || context.canvas.height <= y) return null;
  return decodeVisualTimecodeRow(context.getImageData(x, y, width, 1).data, stride);
}

export function decodeVisualTimecodeRow(
  row: Uint8ClampedArray,
  stride: number = VISUAL_TIMECODE.stride,
) {
  const sampleWidth = (TOTAL_BITS - 1) * stride + 1;
  if (row.byteLength < sampleWidth * 4) return null;
  const bits = Array.from({ length: TOTAL_BITS }, (_, index) => {
    const offset = index * stride * 4;
    const luminance = row[offset] * 0.2126 + row[offset + 1] * 0.7152 + row[offset + 2] * 0.0722;
    return luminance >= 128 ? 1 : 0;
  });
  if (
    VISUAL_TIMECODE.preamble.some((expected, index) => bits[index] !== expected)
  ) {
    return null;
  }

  const grayStart = VISUAL_TIMECODE.preamble.length;
  const gray = bits.slice(grayStart, grayStart + VISUAL_TIMECODE.timestampBits);
  const binary = new Array<number>(VISUAL_TIMECODE.timestampBits).fill(0);
  binary[binary.length - 1] = gray[gray.length - 1] ?? 0;
  for (let index = binary.length - 2; index >= 0; index -= 1) {
    binary[index] = (binary[index + 1] ?? 0) === (gray[index] ?? 0) ? 0 : 1;
  }
  const centiseconds = binary.reduce(
    (value, bit, index) => value + bit * 2 ** index,
    0,
  );

  const checksumStart = grayStart + VISUAL_TIMECODE.timestampBits;
  const checksum = bits
    .slice(checksumStart, checksumStart + VISUAL_TIMECODE.checksumBits)
    .reduce<number>((value, bit, index) => value + bit * 2 ** index, 0);
  if (checksum !== centiseconds % 256) return null;
  return centiseconds * (1_000 / VISUAL_TIMECODE.unitsPerSecond);
}

export function visualTimecodeLatencyMs(timecodeMs: number, nowEpochMs: number) {
  const latency = nowEpochMs - timecodeMs;
  if (!Number.isFinite(latency) || latency < 0 || latency > MAX_TIMECODE_AGE_MS) return null;
  return latency;
}
