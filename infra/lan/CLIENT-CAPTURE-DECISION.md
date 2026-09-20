<!-- SPDX-FileCopyrightText: 2026 Teremoq contributors -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# Client capture telemetry decision

This is a narrowly scoped operator decision for a Windows Core 7.6.6 x64
client report captured at `77a299438039d2b5d7663743a18dca9cf828fef5`.
It is not remote attestation or a claim that the missing parent was observed.
Process basenames can repeat: the producer detects actual PID cycles/reuse and
creation-time instability while walking the process identities. Both validators
retain rejection of those outcomes, depth exhaustion, query failures, malformed
records and visible WSL ancestry/environment.

Only the client `parent_process_missing` outcome may receive this decision.
The original `capture_origin` must remain `observed`,
`warning:indirect-native-powershell`, `real`. A `pass` origin is rejected.
There is no machine-specific ancestor-name allowlist. The bounded name list,
runtime tuple, types, cardinality and all remaining report checks are validated.

## Private evidence and authority

RP must first review independent evidence identifying the actual Windows Core
7.6.6 x64 host and its executable digest and relating that evidence to the client
attempt. Installation history alone does not prove which process executed a
later attempt. Preserve uncertainty explicitly; do not manufacture a receipt,
claim retrospective observation, repeat Prepare/build or alter the original.
If the evidence does not support this decision, do not authorize activation.
The independent text is opaque to the parser: its hash does not validate its
truth or temporal relationship. `host_observation` is an operator-reviewed
declaration, not a new measurement. RP must record any temporal uncertainty as
a warning in the evidence and decision; copying the constants is insufficient.

Supply a separate private JSON envelope through the existing
`--client-preflight` argument. Its closed fields are:

- `schema_version`: integer `1`;
- `report_kind`: `teremoq-client-capture-decision-v1`;
- `disposition`: `operator-reviewed-parent-observation-warning`;
- `run_id`: the actual authorized run;
- `capture_commit`: the exact capture revision above;
- `validation_commit`: the exact new, clean runtime revision;
- `raw_preflight_utf8` and `raw_preflight_sha256`: unchanged original UTF-8
  bytes represented as a JSON string and their SHA-256;
- `independent_evidence_utf8` and `independent_evidence_sha256`: the actual
  reviewed evidence text and its SHA-256, not a fabricated success statement;
- `host_observation`: a closed object with `platform=Windows`, `edition=Core`,
  `version=7.6.6`, `architecture=X64`,
  `executable_sha256=bfb46af89433268872ddb43d1ca7a3f433452ee91ed356a9786940f90118e285`
  and `attempt_binding=operator-reviewed-independent-evidence`.

The envelope is limited to 64 KiB, original text to 24 KiB and independent
evidence to 8 KiB. JSON escaping is reversible; do not parse/reserialize the
original, normalize its line endings or replace its source revision. A hash
provides integrity, not proof of origin. The operator's existing explicit
authorization must bind `client_preflight_sha256` to the **whole envelope**;
retain the raw hash separately inside it and keep both original and envelope.
No secrets or production data belong in this source tree. Transfer permissions
are separate from this parser contract; it does not authorize disclosure.

## Revision transition

Only the enveloped client report may retain the old capture revision. The
runtime, server evidence, configuration, commands, artifacts, firewall and
authorization retain their existing exact new-revision requirements. RP owns
that transition; do not run a dirty old checkout or rename old evidence as new.
IP/profile/run/threshold comparisons still use the actual configured values.
The default raw-report path has no revision exception, and server reports cannot
use this envelope.

This decision does not rebind an installed player's VERSION, receipt or emitted
metrics. Keep its actual revision explicit. It does not approve any separate
player/server compatibility gate, audiovisual result or deployment. No TLS,
fingerprint, namespace, publication capability or firewall check is waived.
