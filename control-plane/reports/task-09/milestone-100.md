# Task 09 local milestone evidence

- Result: `pass`
- Scope: local deterministic control-plane simulation; no real video or provider capacity
- Config digest: `sha256:533176b1adee2016df050ba7d74a68add407c91e8e19d149b0e4c7591a963a7d`
- Report content digest: `sha256:4cd2cd5d463fbd24816e1d76b2b924aa05138deb3aa154cc83f06baad19b0ad0`
- Measured wall execution: `7514527 ns`
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
- The opaque local auth context is test input, not a PKI or signature verification result.
- Unresolved drain preserves assignments; no forced session-termination policy is enabled.
- External provider cost estimates remain unavailable until dated tariffs are supplied.
- The 100-viewer result is simulated control-state evidence, not real media capacity evidence.
