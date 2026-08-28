# Task 09 verification record

- Execution date: 2026-08-28
- Environment: local worktree, Python 3.14.4
- Remote resources created: none
- Credentials used: none
- Remote infrastructure cost measured: 0 EUR

## Commands and measured results

1. `control-plane/scripts/verify.sh`
   - Result: pass
   - Tests: 36 passed, 0 failed
   - Unit/E2E runner time: 0.598 s
   - Whole verify command wall time: 3.15 s
   - Whole verify maximum RSS: 29,364 KiB
   - Configuration validation: pass
   - Python compilation: pass
   - Progressive scenarios executed: 10, 25, 50 and 100 viewers only
2. `control-plane/bin/control-plane --config control-plane/config/milestone-100.json demo --report-dir control-plane/reports/task-09`
   - Result: pass
   - Simulator measured time: 7,514,527 ns
   - Deterministic logical time: 54 s
   - Final gate before failure: 1 origin, 2 distributors, 1 controller
   - Replacement: 1 failed distributor replaced; 100 assignments recovered
   - Cleanup: 0 active sessions; all 4 simulated node records terminated

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

## Evidence hashes

- Canonical configuration: `sha256:533176b1adee2016df050ba7d74a68add407c91e8e19d149b0e4c7591a963a7d`
- Canonical report content: `sha256:4cd2cd5d463fbd24816e1d76b2b924aa05138deb3aa154cc83f06baad19b0ad0`
- Snapshot hashes, audit hash and individual file hashes: see `milestone-100.json` and `SHA256SUMS` in this directory.

## Limitations

This evidence exercises deterministic desired state, scaling decisions,
lifecycle, replacement, session assignment and cleanup. Nodes and sessions are
simulated records. It does not create provider resources, send media, prove
100 real concurrent viewers, validate relay admission, demonstrate production
high availability or supply an external provider price. External estimates
remain unavailable until dated tariffs are configured.
