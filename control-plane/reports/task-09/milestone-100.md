# Task 09 local milestone evidence

- Result: `pass`
- Scope: local deterministic control-plane simulation; no real video or provider capacity
- Config digest: `sha256:ae6d9e003b9a03d25c2928f8c99a9578234fc15f7f8af6a06a704b5fa6dfb8c5`
- Report content digest: `sha256:7d24b9f4c336358d662c48f586b767d95b2e8540954859959b68bf4289a0acf5`
- Measured wall execution: `4671154 ns`
- Logical time: `54 s`

## Demonstrated gate

Progressive viewers: `[10, 25, 50, 100]`. Final topology: `1 origin`, `2 distributors`, `1 control`. No larger scenario was executed.

## Failure and recovery

Failed `milestone-local-core-000002`, created `1` simulated replacement, and recovered `100` session assignments. Distribution after recovery: `{'milestone-local-core-000003': 50, 'milestone-local-core-000004': 50}`.

## Cost boundary

Measured local remote-infrastructure cost: `0.0 EUR`. External provider estimate: `unavailable`; dated external tariffs are required.

## Cleanup

Active sessions: `0`; terminated simulated nodes: `4`.

## Limitations

- The simulator does not create remote resources or forward video.
- The local milestone runs one controller; leases and replicated storage are integration contracts.
- External provider cost estimates remain unavailable until dated tariffs are supplied.
- The 100-viewer result is simulated control-state evidence, not real media capacity evidence.
