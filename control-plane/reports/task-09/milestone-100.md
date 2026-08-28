# Task 09 local milestone evidence

- Result: `pass`
- Scope: local deterministic control-plane simulation; no real video or provider capacity
- Config digest: `sha256:68e94c063b6e3fb51225dd0a815b61e5e3b496d1619fadf5b509003e8be23fe6`
- Report content digest: `sha256:7151edd5c0243db99616f224210c862c5316594045f0ab31a792b0b0e76e417e`
- Measured wall execution: `6118752 ns`
- Logical time: `54 s`

## Demonstrated gate

Progressive viewers: `[10, 25, 50, 100]`. Final topology: `1 origin`, `2 distributors`, `1 control`. No larger scenario was executed.

## Failure and recovery

Failed `milestone-local-core-000002`, emitted ordered create/destroy replacement actions, and recovered `100` session assignments. Distribution after recovery: `{'milestone-local-core-000003': 50, 'milestone-local-core-000004': 50}`.

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
- Action envelope files are local plans; no Platform adapter or transport consumed them.
- The 100-viewer result is simulated control-state evidence, not real media capacity evidence.
