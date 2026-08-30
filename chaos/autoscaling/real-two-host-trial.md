<!-- SPDX-FileCopyrightText: 2026 Teremoq contributors -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# Progressive real two-host trial gate: 10 / 25 / 50 / 100

This is a gated plan, not a claim of executed load or media capacity. The
existing `run.sh` and `run-integrated.sh` remain useful only for lifecycle
regression with counters and inert containers. They do not become real because
their `--viewers` argument is increased. During the release freeze no new
spectator generator may be implemented. A real run is blocked until an already
existing, reviewed external viewer/media harness and authorized spectators are
named explicitly.

## Inputs that must be resolved outside Git

- `REAL_VIEWER_HARNESS_CMD` and immutable harness version/digest;
- `REAL_MEDIA_SOURCE_CMD`, source authorization and correlated
  source/timecode/sequence metadata;
- `AUTHORIZED_VIEWER_MANIFEST` containing exactly the stage audience and no
  credentials in evidence;
- `ACTIVE_SESSION_QUERY_CMD`, `RESERVATION_QUERY_CMD` and
  `DISTRIBUTOR_EGRESS_QUERY_CMD` against real services;
- `MEDIA_PROBE_QUERY_CMD` providing audio gaps, time to first decodable video,
  presentation continuity and clock error;
- per-stage `EGRESS_BUDGET_MBPS`, `RESERVED_CAPACITY_A/B`,
  `DISTRIBUTION_TARGET_A/B` and approved entry/exit thresholds;
- reviewed create/replacement/drain/delete commands from the actual control and
  runtime contracts; and
- private two-host inventory accepted by
  `infra/deployment/two-host/validate-inventory.sh`.

Any missing command, digest, authorization, numeric threshold or query blocks
the real stage. Simulation output cannot fill a missing field.

## Common entry gate for every stage

1. The previous stage exited cleanly (10 has an approved zero-load baseline),
   with a human go/no-go record and no unresolved critical alert.
2. The authorized viewer manifest count equals the stage exactly; unauthorized
   identities and a manifest for another stage are rejected.
3. Source, control, both distributors and media probes report their distinct
   identity, expected digest, host placement, health and registration.
4. Active sessions start at zero; stale reservations are zero. Declared
   reservations plus headroom cover the stage on the intended split without
   exceeding either host's approved egress budget.
5. Kernel, numeric clock offset, UDP/firewall, host capacity, image and identity
   preflights from the two-host runbook pass and are timestamped.
6. Rollback, host-local kill switch and cleanup are rehearsed without viewer
   traffic. Evidence storage and run labels are unique.

## Stage matrix

| Stage | Authorized/active requirement | Distribution and capacity | Failure/recovery exercise | Exit requirement |
| ---: | --- | --- | --- | --- |
| 10 | exactly 10 authorized viewers; active real MoQT sessions must converge to 10, never a counter substitute | targets A+B must total 10; compare real reservations and measured egress with both approved budgets | controlled distributor failure only after stable media; generation-distinct healthy registered replacement | all 10 sessions accounted for; audiovisual metrics within approved thresholds; drain then delete; zero run-labelled residue |
| 25 | exactly 25; 10-stage evidence accepted first | targets total 25; prove reservations before admission and record whether existing capacity suffices | repeat failure/substitution without reusing stale identity or registration | same invariants at 25; no unauthorized session; zero stale reservations/resources |
| 50 | exactly 50; 25-stage exit accepted | targets total 50; if scale-out is planned here, consume a real authorized create, verify digest/placement/health/registration before admission | fail the designated distributor, transfer only after replacement readiness and measure recovery | same invariants at 50; created capacity drained and removed or retained by explicit change record |
| 100 | exactly 100; 50-stage exit accepted | targets total 100; a real capacity creation must have been demonstrated at 25, 50 or 100 before this stage can exit | full controlled create/failure/substitution/rollback path, then planned drain of the other distributor | 100 sessions accounted for, real egress and recovery evidence accepted, all trial capacity drained/deleted, zero run-labelled residue |

The distribution need not be 50/50, but `DISTRIBUTION_TARGET_A +
DISTRIBUTION_TARGET_B` must equal the stage, match reservations, remain within
measured egress and be justified before admission. A configuration-only
capacity change is not a capacity creation. A real create is counted only when
a distinct instance with approved image digest, service identity, host
placement, health and registration becomes admissible.

## Measurable audiovisual recovery

Before injection, establish a stable window using the same authorized media
source and independent output probes on both distributors. Correlate media by
source ID, PTS/timecode and sequence. Record at least:

- last correlated good audio/video before injection;
- first audio after reroute and audio gap duration;
- first decodable video access point and presentation after reroute;
- `media_recovery_ms`, per-probe p50/p95/p99 over the approved observation
  window, dropped/late objects and session reconnects; and
- numeric source/host/probe clock error and measurement uncertainty.

The stage fails if any approved recovery/gap/session-loss threshold is absent
or exceeded, if the first returned video is stale, if probes cannot correlate
the same media unit, or if only container/session counters are available. Do
not label local replacement time as audiovisual recovery.

## Exit, rollback and cleanup

At each stage: stop new admissions; reconcile authorized versus active
sessions; move sessions; require source/distributor reservations to reach zero;
obtain drain acknowledgement; delete only the intended generation; restore the
last complete route on rollback; and inventory containers, networks, volumes,
provider/runtime instances, registrations and firewall rules by run label on
both hosts. Any residue blocks progression.

The 1,000-viewer stage remains explicitly blocked. There is no profile,
authorization, capacity evidence, real viewer harness evidence or HA basis for
it. Raising a numeric limit or replaying simulated counters cannot unblock it.
