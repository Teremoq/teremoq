import { describe, expect, it } from "vitest";
import type { MoqObject } from "../moqt/subgroup";
import { ObjectReorderBuffer } from "./object-reorder-buffer";

function object(groupId: number, subgroupId: number): MoqObject {
  return {
    trackAlias: 2,
    groupId,
    subgroupId,
    publisherPriority: subgroupId === 0 ? 1 : 2,
    objectIdDelta: 0,
    streamObjectIndex: 0,
    status: null,
    payload: Uint8Array.of(groupId, subgroupId),
  };
}

describe("ObjectReorderBuffer", () => {
  it("no descarta un keyframe que llega después de sus deltas", () => {
    const buffer = new ObjectReorderBuffer();

    expect(buffer.push(object(7, 2)).ready).toEqual([]);
    expect(buffer.push(object(7, 1)).ready).toEqual([]);
    const result = buffer.push(object(7, 0));

    expect(result.ready.map((value) => value.subgroupId)).toEqual([0, 1, 2]);
    expect(result.dropped).toBe(0);
    expect(result.resync).toBe(true);
  });

  it("mantiene orden continuo cuando los streams QUIC terminan desordenados", () => {
    const buffer = new ObjectReorderBuffer();
    const output = [0, 2, 1, 4, 3].flatMap(
      (subgroupId) => buffer.push(object(9, subgroupId)).ready,
    );

    expect(output.map((value) => value.subgroupId)).toEqual([0, 1, 2, 3, 4]);
  });

  it("abandona un Group incompleto al recibir el siguiente keyframe", () => {
    const buffer = new ObjectReorderBuffer();
    buffer.push(object(11, 0));
    buffer.push(object(11, 2));
    buffer.push(object(12, 2));
    const result = buffer.push(object(12, 0));

    expect(result.ready.map((value) => [value.groupId, value.subgroupId])).toEqual([[12, 0]]);
    expect(result.dropped).toBe(1);
    expect(result.resync).toBe(true);
  });

  it("no reinicia el decoder al avanzar entre Groups completos", () => {
    const buffer = new ObjectReorderBuffer();
    buffer.push(object(15, 0));
    buffer.push(object(15, 1));

    const result = buffer.push(object(16, 0));

    expect(result.ready.map((value) => [value.groupId, value.subgroupId])).toEqual([[16, 0]]);
    expect(result.dropped).toBe(0);
    expect(result.resync).toBe(false);
  });

  it("descarta duplicados y Objects de Groups obsoletos", () => {
    const buffer = new ObjectReorderBuffer();
    buffer.push(object(20, 0));

    expect(buffer.push(object(20, 0)).dropped).toBe(1);
    buffer.push(object(21, 0));
    expect(buffer.push(object(20, 1)).dropped).toBe(1);
  });
});
