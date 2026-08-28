const MAX_SAFE_QUIC_VARINT = Number.MAX_SAFE_INTEGER;

export class MoqProtocolError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "MoqProtocolError";
  }
}

export class ByteWriter {
  readonly #bytes: number[] = [];

  writeVarInt(value: number) {
    assertSafeInteger(value, "QUIC varint");
    if (value < 2 ** 6) {
      this.#bytes.push(value);
    } else if (value < 2 ** 14) {
      this.#bytes.push(0x40 | Math.floor(value / 256), value & 0xff);
    } else if (value < 2 ** 30) {
      this.#bytes.push(
        0x80 | Math.floor(value / 2 ** 24),
        Math.floor(value / 2 ** 16) & 0xff,
        Math.floor(value / 2 ** 8) & 0xff,
        value & 0xff,
      );
    } else {
      const encoded = new Array<number>(8);
      let remaining = value;
      for (let index = 7; index >= 0; index -= 1) {
        encoded[index] = remaining % 256;
        remaining = Math.floor(remaining / 256);
      }
      encoded[0] |= 0xc0;
      this.#bytes.push(...encoded);
    }
  }

  writeU8(value: number) {
    if (!Number.isInteger(value) || value < 0 || value > 0xff) {
      throw new MoqProtocolError(`u8 fuera de rango: ${value}`);
    }
    this.#bytes.push(value);
  }

  writeU16(value: number) {
    if (!Number.isInteger(value) || value < 0 || value > 0xffff) {
      throw new MoqProtocolError(`u16 fuera de rango: ${value}`);
    }
    this.#bytes.push(value >> 8, value & 0xff);
  }

  writeBytes(value: Uint8Array) {
    this.#bytes.push(...value);
  }

  writePrefixedBytes(value: Uint8Array) {
    this.writeVarInt(value.byteLength);
    this.writeBytes(value);
  }

  toUint8Array() {
    return Uint8Array.from(this.#bytes);
  }
}

export class ByteCursor {
  #offset = 0;

  constructor(readonly bytes: Uint8Array) {}

  get remaining() {
    return this.bytes.byteLength - this.#offset;
  }

  readVarInt() {
    const first = this.readU8();
    const length = 1 << (first >> 6);
    let value = first & 0x3f;
    for (let index = 1; index < length; index += 1) {
      value = value * 256 + this.readU8();
      if (value > MAX_SAFE_QUIC_VARINT) {
        throw new MoqProtocolError("QUIC varint supera el rango seguro de JavaScript");
      }
    }
    return value;
  }

  readU8() {
    if (this.remaining < 1) {
      throw new MoqProtocolError("payload MoQT truncado");
    }
    const value = this.bytes[this.#offset];
    this.#offset += 1;
    return value;
  }

  readU16() {
    const high = this.readU8();
    return high * 256 + this.readU8();
  }

  readBytes(length: number) {
    if (!Number.isSafeInteger(length) || length < 0 || length > this.remaining) {
      throw new MoqProtocolError(`longitud inválida o truncada: ${length}`);
    }
    const value = this.bytes.subarray(this.#offset, this.#offset + length);
    this.#offset += length;
    return value;
  }
}

export class AsyncByteReader {
  readonly #reader: ReadableStreamDefaultReader<Uint8Array>;
  readonly #maximumBuffered: number;
  #chunks: Uint8Array[] = [];
  #chunkOffset = 0;
  #buffered = 0;
  #done = false;
  #aborted = false;
  readonly #signal: AbortSignal | null;
  readonly #abortHandler: (() => void) | null;

  constructor(
    stream: ReadableStream<Uint8Array>,
    maximumBuffered = 128 * 1024,
    signal?: AbortSignal,
  ) {
    this.#reader = stream.getReader();
    this.#maximumBuffered = maximumBuffered;
    this.#signal = signal ?? null;
    this.#abortHandler = signal
      ? () => {
          this.#aborted = true;
          this.#done = true;
          this.#chunks = [];
          this.#chunkOffset = 0;
          this.#buffered = 0;
          void this.#reader.cancel("lectura cancelada").catch(() => undefined);
        }
      : null;
    if (signal?.aborted) this.#abortHandler?.();
    else if (signal && this.#abortHandler) {
      signal.addEventListener("abort", this.#abortHandler, { once: true });
    }
  }

  async readVarInt() {
    const first = await this.readVarIntOrEof();
    if (first === null) throw new MoqProtocolError("stream MoQT truncado");
    return first;
  }

  async readVarIntOrEof() {
    await this.#fill(1);
    this.#throwIfAborted();
    if (this.#buffered === 0 && this.#done) return null;
    const first = (await this.readExact(1))[0];
    const length = 1 << (first >> 6);
    let value = first & 0x3f;
    if (length > 1) {
      for (const byte of await this.readExact(length - 1)) {
        value = value * 256 + byte;
        if (value > MAX_SAFE_QUIC_VARINT) {
          throw new MoqProtocolError("QUIC varint supera el rango seguro de JavaScript");
        }
      }
    }
    return value;
  }

  async readU16() {
    const value = await this.readExact(2);
    return value[0] * 256 + value[1];
  }

  async readExact(length: number) {
    this.#throwIfAborted();
    if (!Number.isSafeInteger(length) || length < 0) {
      throw new MoqProtocolError(`lectura inválida: ${length}`);
    }
    await this.#fill(length);
    this.#throwIfAborted();
    if (this.#buffered < length) {
      throw new MoqProtocolError("stream MoQT truncado");
    }

    const result = new Uint8Array(length);
    let written = 0;
    while (written < length) {
      const chunk = this.#chunks[0];
      const available = chunk.byteLength - this.#chunkOffset;
      const take = Math.min(available, length - written);
      result.set(chunk.subarray(this.#chunkOffset, this.#chunkOffset + take), written);
      written += take;
      this.#chunkOffset += take;
      this.#buffered -= take;
      if (this.#chunkOffset === chunk.byteLength) {
        this.#chunks.shift();
        this.#chunkOffset = 0;
      }
    }
    return result;
  }

  async readAll(limit: number) {
    this.#throwIfAborted();
    if (limit > this.#maximumBuffered) {
      throw new MoqProtocolError("el límite solicitado supera el máximo del lector");
    }
    while (!this.#done) {
      await this.#readChunk(limit);
    }
    this.#throwIfAborted();
    if (this.#buffered > limit) {
      throw new MoqProtocolError(`stream supera el límite de ${limit} bytes`);
    }
    return this.readExact(this.#buffered);
  }

  async cancel(reason: string) {
    if (this.#aborted) return;
    this.#aborted = true;
    this.#done = true;
    this.#detachAbortHandler();
    this.#chunks = [];
    this.#chunkOffset = 0;
    this.#buffered = 0;
    await this.#reader.cancel(reason);
  }

  async #fill(length: number) {
    while (this.#buffered < length && !this.#done) {
      this.#throwIfAborted();
      await this.#readChunk(this.#maximumBuffered);
    }
  }

  async #readChunk(limit: number) {
    this.#throwIfAborted();
    const { value, done } = await this.#reader.read();
    this.#throwIfAborted();
    if (done) {
      this.#done = true;
      this.#detachAbortHandler();
      return;
    }
    if (!(value instanceof Uint8Array) || value.byteLength === 0) {
      return;
    }
    if (this.#buffered + value.byteLength > limit) {
      await this.#reader.cancel("límite MoQT excedido");
      this.#done = true;
      this.#detachAbortHandler();
      throw new MoqProtocolError(`stream supera el límite de ${limit} bytes`);
    }
    this.#chunks.push(value);
    this.#buffered += value.byteLength;
  }

  #throwIfAborted() {
    if (!this.#aborted) return;
    const error = new Error("lectura cancelada");
    error.name = "AbortError";
    throw error;
  }

  #detachAbortHandler() {
    if (this.#signal && this.#abortHandler) {
      this.#signal.removeEventListener("abort", this.#abortHandler);
    }
  }
}

export function concatBytes(...parts: Uint8Array[]) {
  const length = parts.reduce((total, part) => total + part.byteLength, 0);
  const result = new Uint8Array(length);
  let offset = 0;
  for (const part of parts) {
    result.set(part, offset);
    offset += part.byteLength;
  }
  return result;
}

function assertSafeInteger(value: number, label: string) {
  if (!Number.isSafeInteger(value) || value < 0 || value > MAX_SAFE_QUIC_VARINT) {
    throw new MoqProtocolError(`${label} fuera de rango: ${value}`);
  }
}
