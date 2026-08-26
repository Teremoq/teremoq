import type { MoqObject } from "../moqt/subgroup";

const MAX_BUFFERED_GROUPS = 2;
const MAX_BUFFERED_OBJECTS = 64;
const MAX_BUFFERED_BYTES = 16 * 1024 * 1024;

export type ReorderResult = {
  ready: MoqObject[];
  dropped: number;
  resync: boolean;
};

type BufferedGroup = {
  objects: Map<number, MoqObject>;
  bytes: number;
};

/**
 * Restores media order across independent QUIC streams. Subgroups can complete
 * out of order even though their IDs describe one ordered H.264 dependency
 * chain. A newer subgroup must therefore never make a late keyframe look stale.
 */
export class ObjectReorderBuffer {
  readonly #groups = new Map<number, BufferedGroup>();
  #currentGroup: number | null = null;
  #nextSubgroup = 0;
  #objects = 0;
  #bytes = 0;

  push(object: MoqObject): ReorderResult {
    const result: ReorderResult = { ready: [], dropped: 0, resync: false };
    const sequence = object.subgroupId + object.streamObjectIndex;
    if (this.#currentGroup !== null && object.groupId < this.#currentGroup) {
      result.dropped = 1;
      return result;
    }
    if (
      this.#currentGroup === object.groupId &&
      sequence < this.#nextSubgroup
    ) {
      result.dropped = 1;
      return result;
    }

    let group = this.#groups.get(object.groupId);
    if (!group) {
      group = { objects: new Map(), bytes: 0 };
      this.#groups.set(object.groupId, group);
    }
    if (group.objects.has(sequence)) {
      result.dropped = 1;
      return result;
    }
    group.objects.set(sequence, object);
    group.bytes += object.payload.byteLength;
    this.#objects += 1;
    this.#bytes += object.payload.byteLength;

    if (
      this.#groups.size > MAX_BUFFERED_GROUPS ||
      this.#objects > MAX_BUFFERED_OBJECTS ||
      this.#bytes > MAX_BUFFERED_BYTES
    ) {
      result.dropped += this.#clear();
      result.resync = true;
      return result;
    }

    const keyGroup = this.#oldestGroupWithKey();
    if (
      keyGroup !== null &&
      (this.#currentGroup === null ||
        (keyGroup > this.#currentGroup && !this.#currentHasNext()))
    ) {
      const initialSynchronization = this.#currentGroup === null;
      const dropped = this.#promote(keyGroup);
      result.dropped += dropped;
      result.resync = initialSynchronization || dropped > 0;
    }
    this.#drain(result.ready);
    return result;
  }

  reset() {
    this.#clear();
  }

  #oldestGroupWithKey() {
    let candidate: number | null = null;
    for (const [groupId, group] of this.#groups) {
      if (!group.objects.has(0) || groupId === this.#currentGroup) continue;
      if (candidate === null || groupId < candidate) candidate = groupId;
    }
    if (
      this.#currentGroup !== null &&
      this.#groups.get(this.#currentGroup)?.objects.has(0)
    ) {
      return this.#currentGroup;
    }
    return candidate;
  }

  #currentHasNext() {
    return this.#currentGroup !== null &&
      (this.#groups.get(this.#currentGroup)?.objects.has(this.#nextSubgroup) ?? false);
  }

  #promote(groupId: number) {
    let dropped = 0;
    for (const candidate of [...this.#groups.keys()]) {
      if (candidate >= groupId) continue;
      dropped += this.#removeGroup(candidate);
    }
    this.#currentGroup = groupId;
    this.#nextSubgroup = 0;
    return dropped;
  }

  #drain(ready: MoqObject[]) {
    if (this.#currentGroup === null) return;
    const group = this.#groups.get(this.#currentGroup);
    if (!group) return;
    while (true) {
      const object = group.objects.get(this.#nextSubgroup);
      if (!object) return;
      group.objects.delete(this.#nextSubgroup);
      group.bytes -= object.payload.byteLength;
      this.#objects -= 1;
      this.#bytes -= object.payload.byteLength;
      this.#nextSubgroup += 1;
      ready.push(object);
    }
  }

  #removeGroup(groupId: number) {
    const group = this.#groups.get(groupId);
    if (!group) return 0;
    this.#groups.delete(groupId);
    this.#objects -= group.objects.size;
    this.#bytes -= group.bytes;
    return group.objects.size;
  }

  #clear() {
    const dropped = this.#objects;
    this.#groups.clear();
    this.#currentGroup = null;
    this.#nextSubgroup = 0;
    this.#objects = 0;
    this.#bytes = 0;
    return dropped;
  }
}
