import {
  DataStream,
  Endianness,
  MP4BoxBuffer,
  createFile,
  type MultiBufferStream,
  type Sample,
} from "mp4box";

const MAX_SAMPLES_PER_CALLBACK = 32;

export type DemuxedVideoSample = {
  data: Uint8Array<ArrayBuffer>;
  timestampUs: number;
  durationUs: number;
  key: boolean;
  receivedAtMs: number;
};

export type VideoConfiguration = {
  codec: string;
  codedWidth: number;
  codedHeight: number;
  description: ArrayBuffer;
};

export class CmafDemuxer {
  readonly #file = createFile();
  readonly #onConfiguration: (configuration: VideoConfiguration) => void;
  readonly #onSample: (sample: DemuxedVideoSample) => void;
  readonly #onError: (error: Error) => void;
  #offset = 0;
  #trackId: number | null = null;
  #trackCodec = "";
  #trackWidth = 0;
  #trackHeight = 0;
  #configured = false;
  #receivedAtMs = 0;

  constructor(callbacks: {
    onConfiguration: (configuration: VideoConfiguration) => void;
    onSample: (sample: DemuxedVideoSample) => void;
    onError: (error: Error) => void;
  }) {
    this.#onConfiguration = callbacks.onConfiguration;
    this.#onSample = callbacks.onSample;
    this.#onError = callbacks.onError;
    this.#file.onError = (module, message) =>
      this.#onError(new Error(`MP4Box ${module}: ${message}`));
    this.#file.onReady = (info) => {
      const track = info.videoTracks[0];
      if (!track?.video || (!track.codec.startsWith("avc1.") && !track.codec.startsWith("avc3."))) {
        this.#onError(new Error("la inicialización CMAF no contiene vídeo AVC"));
        return;
      }
      this.#trackId = track.id;
      this.#trackCodec = track.codec;
      this.#trackWidth = track.video.width;
      this.#trackHeight = track.video.height;
      this.#file.setExtractionOptions(track.id, undefined, {
        nbSamples: MAX_SAMPLES_PER_CALLBACK,
      });
      this.#file.start();
    };
    this.#file.onSamples = (trackId, _user, samples) => this.#handleSamples(trackId, samples);
  }

  initialize(initialization: Uint8Array) {
    if (this.#offset !== 0) throw new Error("CmafDemuxer ya inicializado");
    this.#append(initialization);
    if (this.#trackId === null) {
      throw new Error("MP4Box no pudo leer el moov CMAF");
    }
  }

  appendFragment(fragment: Uint8Array, receivedAtMs: number) {
    if (this.#trackId === null) throw new Error("CmafDemuxer no inicializado");
    this.#receivedAtMs = receivedAtMs;
    this.#append(fragment);
  }

  flush() {
    this.#file.flush();
  }

  #append(bytes: Uint8Array) {
    const copy = new Uint8Array(bytes.byteLength);
    copy.set(bytes);
    const buffer = MP4BoxBuffer.fromArrayBuffer(copy.buffer, this.#offset);
    this.#offset += bytes.byteLength;
    this.#file.appendBuffer(buffer);
  }

  #handleSamples(trackId: number, samples: Sample[]) {
    if (trackId !== this.#trackId) return;
    for (const sample of samples) {
      if (!sample.data) {
        this.#onError(new Error("muestra CMAF sin payload"));
        continue;
      }
      if (!this.#configured) {
        this.#onConfiguration({
          codec: this.#trackCodec,
          codedWidth: this.#trackWidth,
          codedHeight: this.#trackHeight,
          description: decoderDescription(sample),
        });
        this.#configured = true;
      }
      this.#onSample({
        data: sample.data,
        timestampUs: Math.round((sample.cts * 1_000_000) / sample.timescale),
        durationUs: Math.max(1, Math.round((sample.duration * 1_000_000) / sample.timescale)),
        key: sample.is_sync,
        receivedAtMs: this.#receivedAtMs,
      });
      this.#file.releaseUsedSamples(trackId, sample.number + 1);
    }
  }
}

function decoderDescription(sample: Sample) {
  const description = sample.description;
  if (!hasWritableAvcC(description)) {
    throw new Error("sample entry AVC sin avcC");
  }
  const stream = new DataStream(undefined, 0, Endianness.BIG_ENDIAN);
  description.avcC.write(stream as unknown as MultiBufferStream);
  if (stream.byteLength <= 8) throw new Error("avcC vacío");
  const result = new ArrayBuffer(stream.byteLength - 8);
  new Uint8Array(result).set(new Uint8Array(stream.buffer, 8, stream.byteLength - 8));
  return result;
}

function hasWritableAvcC(
  value: unknown,
): value is { avcC: { write: (stream: MultiBufferStream) => void } } {
  if (typeof value !== "object" || value === null || !("avcC" in value)) return false;
  const avcC = value.avcC;
  return typeof avcC === "object" && avcC !== null && "write" in avcC && typeof avcC.write === "function";
}
