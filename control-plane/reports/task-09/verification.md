# Task 09 verification record

- Execution date: 2026-08-28
- Environment: local worktree, Python 3.14.4
- Remote resources created: none
- Credentials used: none
- Remote infrastructure cost measured: 0 EUR

## Commands and measured results

1. `control-plane/scripts/verify.sh`
   - Result: pass
   - Tests: 47 passed, 0 failed
   - Unit/E2E runner time: 0.608 s
   - Whole verify command wall time: 2.51 s
   - Whole verify maximum RSS: 29,408 KiB
   - Configuration validation: pass
   - Python compilation: pass
   - Progressive scenarios executed: 10, 25, 50 and 100 viewers only
2. `control-plane/bin/control-plane --config control-plane/config/milestone-100.json demo --report-dir control-plane/reports/task-09`
   - Result: pass
   - Simulator measured time: 6,118,752 ns
   - Deterministic logical time: 54 s
   - Final gate before failure: 1 origin, 2 distributors, 1 controller
   - Replacement: 1 failed distributor replaced; 100 assignments recovered
   - Cleanup: 0 active sessions; all 4 simulated node records terminated
   - Local action files: bootstrap, scale-out, ordered replacement and cleanup

## Independent-review corrections exercised

- Real metrics, audit-event and desired-state serializers match their schemas
  and are checked by stdlib validators.
- Missing external verified-auth context and an excessive first demand sample
  fail closed without provider actions.
- A full reservation registry rejects a six-sample flood without evicting live
  replay records, then accepts new state after their expiry.
- Session overflow is rejected atomically; the final 100 assignments remain
  50/50 over two distributors with configured capacity 60 each.
- Drain without a ready peer preserves all assignments and emits
  `node_drain_unresolved`, never `node_drained`; replacement of the only
  distributor creates ready capacity before moving its sessions.
- Versioned action envelopes match the real serializer and reject unknown
  fields, semantic tampering, stale generations, replay and configured
  cardinality/byte/idempotency-registry overflow.
- Create actions carry neutral viewer/egress capacity, immutable digests,
  placement, logical deadline and optional replacement link. Destroy actions
  retain node generation and require drain.
- Successful replacement emits ordered `create,destroy`; unresolved replacement
  preserves sessions and defers destroy to an explicit retry. Final cleanup
  covers pending replacement resources and leaves every simulated node
  terminated.
- Action reasons are a closed low-cardinality enum. Metrics and desired-state
  schema numeric/cardinality safety limits match stdlib validation, with
  equal-or-smaller run-specific limits applied fail closed.

## Evidence hashes

- Canonical configuration: `sha256:68e94c063b6e3fb51225dd0a815b61e5e3b496d1619fadf5b509003e8be23fe6`
- Canonical report content: `sha256:7151edd5c0243db99616f224210c862c5316594045f0ab31a792b0b0e76e417e`
- Snapshot hashes, audit hash and individual file hashes: see `milestone-100.json` and `SHA256SUMS` in this directory.

## Limitations

This evidence exercises deterministic desired state, scaling decisions,
lifecycle, replacement, session assignment and cleanup. Nodes and sessions are
simulated records. It does not create provider resources, send media, prove
100 real concurrent viewers, validate relay admission, demonstrate production
high availability or supply an external provider price. External estimates
remain unavailable until dated tariffs are configured. The action files are
validated local plans only: no Platform adapter, durable store, transport or
provider executed or accepted them.
