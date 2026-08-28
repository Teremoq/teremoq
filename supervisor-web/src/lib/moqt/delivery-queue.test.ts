import { describe, expect, it } from "vitest";
import type { MoqObject } from "./subgroup";
import { TrackDeliveryQueue } from "./delivery-queue";

function object(groupId: number, subgroupId: number, bytes = 1): MoqObject {
  return {
    trackAlias: 1,
    groupId,
    subgroupId,
    publisherPriority: subgroupId === 0 ? 1 : 2,
    objectIdDelta: 0,
    streamObjectIndex: 0,
    status: null,
    payload: new Uint8Array(bytes),
  };
}

function deferred() {
  let resolve: (() => void) | null = null;
  const promise = new Promise<void>((done) => { resolve = done; });
  return {
    promise,
    resolve() {
      if (!resolve) throw new Error("deferred no inicializado");
      resolve();
    },
  };
}

async function flushMicrotasks() {
  await Promise.resolve();
  await Promise.resolve();
}

describe("TrackDeliveryQueue", () => {
  it("descarta sólo vídeo delta al saturarse", async () => {
    const gate = deferred();
    const delivered: number[] = [];
    const queue = new TrackDeliveryQueue(
      async (current) => {
        delivered.push(current.subgroupId);
        if (current.subgroupId === 0) await gate.promise;
      },
      "video",
      () => undefined,
      { maximumObjects: 3, maximumBytes: 64 },
    );

    expect(queue.enqueue(object(1, 0))).toBe("queued");
    await flushMicrotasks();
    expect(queue.enqueue(object(1, 1))).toBe("queued");
    expect(queue.enqueue(object(1, 2))).toBe("queued");
    expect(queue.enqueue(object(1, 3))).toBe("video-dropped");
    expect(queue.pendingObjects).toBe(3);

    gate.resolve();
    await flushMicrotasks();
    expect(delivered).toContain(0);
  });

  it("vacía deltas pendientes para aceptar un keyframe nuevo", async () => {
    const gate = deferred();
    const delivered: Array<[number, number]> = [];
    const queue = new TrackDeliveryQueue(
      async (current) => {
        delivered.push([current.groupId, current.subgroupId]);
        if (current.groupId === 1) await gate.promise;
      },
      "video",
      () => undefined,
      { maximumObjects: 3, maximumBytes: 64 },
    );
    queue.enqueue(object(1, 0));
    await flushMicrotasks();
    queue.enqueue(object(1, 1));
    queue.enqueue(object(1, 2));

    expect(queue.enqueue(object(2, 0))).toBe("video-resynced");
    gate.resolve();
    await flushMicrotasks();
    await flushMicrotasks();

    expect(delivered).toEqual([[1, 0], [2, 0]]);
  });

  it("nunca descarta silenciosamente una cola crítica", () => {
    const queue = new TrackDeliveryQueue(
      () => new Promise<void>(() => undefined),
      "critical",
      () => undefined,
      { maximumObjects: 2, maximumBytes: 2 },
    );

    expect(queue.enqueue(object(1, 0))).toBe("queued");
    expect(queue.enqueue(object(1, 1))).toBe("queued");
    expect(queue.enqueue(object(1, 2))).toBe("overflow");
  });

  it("entrega telemetría aunque la cola de vídeo esté saturada", async () => {
    const videoGate = deferred();
    const video = new TrackDeliveryQueue(
      () => videoGate.promise,
      "video",
      () => undefined,
      { maximumObjects: 1 },
    );
    const telemetrySequences: number[] = [];
    const telemetry = new TrackDeliveryQueue(
      (current) => { telemetrySequences.push(current.groupId); },
      "critical",
      () => undefined,
    );
    video.enqueue(object(1, 0));

    for (let sequence = 0; sequence < 16; sequence += 1) {
      expect(telemetry.enqueue(object(sequence, 0))).toBe("queued");
      await flushMicrotasks();
    }

    expect(telemetrySequences).toEqual([...Array(16).keys()]);
    videoGate.resolve();
  });
});
