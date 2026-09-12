<!-- SPDX-FileCopyrightText: 2026 Teremoq contributors -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# Managed launcher composition (preparation, not media evidence)

This delta targets the existing managed client layout at baseline
`a74d0b476b55b0d59b13bab64555c3e17e2c655a`. It does not create a launcher,
change media/evidence schemas, or enable the frozen coordination channel.

`Prepare-LanClientFromGit` validates the selected candidate with the sealed
launcher's Start parser before reporting pending health; failure enters the
existing A/B rollback path. `Verify-Package` and `Invoke-LanLoad -Action Validate`
use the same parser. Preparation/build/activation remain mutating actions;
their final validation does **not** establish health or authorize a test.

The shared Platform call uses `-Action Start -ValidateOnly -StateRoot` plus
the exact RunId, Level, VersionPath and FingerprintPath from verified managed
state, and a deterministic EvidenceDirectory. No new action is added to
`lan-launcher.tsv`. Start passes the same StateRoot and paths and revalidates.
Validate does not run `node --version`, launch a child product process, create
evidence or reserve a port. Read-only Git checks still execute Git; this is not
a claim of zero OS processes for the entire wrapper.

Before loading any launcher code, Platform opens the approved manifest and
checks its SHA-256 against the already-verified context using the retained
handle. It parses the inventory from that same handle, opens every inventoried
file with `FileShare.Read`, and checks size/hash from those retained handles.
Only after all pins and the exact inventory pass does it call the launcher.
The pins remain held throughout that invocation and are released in `finally`,
including partial acquisition, parser errors and nonzero script exit. Both
ValidateOnly and real action invocations use this protector. A second pathname
hash followed by an unprotected call, or a launcher self-check after loading,
is not accepted as protection. These pins cover artifact code/dependencies
for the invocation; they are not an assertion about an entire later AV session.

Managed state selection opens the existing operation lock read-only with
`FileShare.Read`: concurrent readers are allowed; writers and deletion are
excluded. This is not an exclusive mutex between readers. The shared verified
reader retries Windows sharing/lock errors 32/33 for at most 20 attempts,
waiting 250 ms between attempts and revalidating the pathname each time.
It never creates that lock, initializes directories, repairs control files or
removes partial state. Missing locks, writer conflicts that exhaust the bounded
retry policy, or recovery-needed
control entries reject validation. Explicit update/recovery operations retain
their existing mutating lock/repair behavior.

The Web owner validates `control/active.json` (closed record), VERSION v2 and
config v1 (six physical keys), exact slot/player paths, all cross-bindings and
the sealed inventory. The slot formula remains
`u-<updater_commit>-p-<player_identity hex>`; player location remains
`players/sha256-<identity hex>`. A different valid inactive VERSION is not
accepted. The Web runtime adds `source_commit=updater_commit` only in memory
after verification; that is execution/evidence provenance, not player build
identity. Nothing is copied beside or written into the immutable player.

`launcher-composition-policy-test.sh` checks wiring without Windows.
`launcher-composition-fixture.ps1` tests the adapter on native PowerShell 5,
including launcher/dependency substitution after context selection (rejected
without executing substituted code), manifest substitution, write/replacement
denial during invocation, partial pin cleanup, unknown parameters, parser
rejection and nonzero script exit.
`client-slot-state-test.ps1` tests non-mutating reads, missing lock rejection,
concurrency and preserved partial files. These are not the sealed Web E2E:
composition with the owner's final launcher commit remains an integration gate.
Legacy launchers must reject ValidateOnly; no fallback may label them ready.

No video, PKI emission, socket, firewall, WSL or container operation is
authorized by these validations. Audio, source selection, baseline/recovery
evidence and measurement sufficiency remain separate acceptance gates.
