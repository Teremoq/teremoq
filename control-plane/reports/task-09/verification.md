# Task 09 verification record

- Execution date: 2026-08-28
- Environment: local worktree, Python 3.14.4
- Remote resources created: none
- Credentials used: none
- Remote infrastructure cost measured: 0 EUR

## Commands and measured results

1. `control-plane/scripts/verify.sh`
   - Result: pass
   - Tests: 27 passed, 0 failed
   - Unit/E2E runner time: 0.401 s
   - Whole verify command wall time: 2.45 s
   - Whole verify maximum RSS: 29,292 KiB
   - Configuration validation: pass
   - Python compilation: pass
   - Progressive scenarios executed: 10, 25, 50 and 100 viewers only
2. `control-plane/bin/control-plane --config control-plane/config/milestone-100.json demo --report-dir control-plane/reports/task-09`
   - Result: pass
   - Simulator measured time: 4,671,154 ns
   - Deterministic logical time: 54 s
   - Final gate before failure: 1 origin, 2 distributors, 1 controller
   - Replacement: 1 failed distributor replaced; 100 assignments recovered
   - Cleanup: 0 active sessions; all 4 simulated node records terminated

## Evidence hashes

- Canonical configuration: `sha256:ae6d9e003b9a03d25c2928f8c99a9578234fc15f7f8af6a06a704b5fa6dfb8c5`
- Canonical report content: `sha256:7d24b9f4c336358d662c48f586b767d95b2e8540954859959b68bf4289a0acf5`
- Snapshot hashes, audit hash and individual file hashes: see `milestone-100.json` and `SHA256SUMS` in this directory.

## Limitations

This evidence exercises deterministic desired state, scaling decisions,
lifecycle, replacement, session assignment and cleanup. Nodes and sessions are
simulated records. It does not create provider resources, send media, prove
100 real concurrent viewers, validate relay admission, demonstrate production
high availability or supply an external provider price. External estimates
remain unavailable until dated tariffs are configured.
