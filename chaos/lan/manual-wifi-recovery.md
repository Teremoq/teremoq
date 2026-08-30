<!-- SPDX-FileCopyrightText: 2026 Teremoq contributors -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# Manual client Wi-Fi recovery measurement

Perform this only at the accepted one-player stage, with an operator physically
at the Windows 10 client. Do not script `netsh`, adapter disablement, airplane
mode, router changes or global Windows networking.

1. Confirm 10 minutes of authorized real playback, calibrated clock error,
   source correlation, active session count and zero pending cleanup.
2. Start the TP-WEB-REALTIME `Collect` action and a monotonic stopwatch; annotate
   the last correlated media unit. Manually disconnect the client from the selected private Wi-Fi using
   the Windows network UI for the approved brief interval.
3. Manually reconnect to the same SSID. Confirm the client obtains the same
   approved exact private address; otherwise stop and rerun every preflight and
   firewall plan before reconnecting the player.
4. Record player-exposed session state, first current decodable video and
   presentation time. Record ICMP RTT/loss/jitter only as a network
   approximation; do not relabel it as QUIC telemetry. Do not count a stale
   frame as recovery.
5. Record `wifi_recovery_ms`, session reconnects, video recovery, clock error
   and uncertainty in the checksum-bound player/host evidence. The reused
   `run-source.sh` harness is video-only, so audio recovery is `not_measured`
   and this run cannot claim audiovisual recovery. If correlation is unavailable, mark the field
   `unavailable` or `not_measured`, never zero.
6. Stop admission and the player, roll back the exact run firewall group and
   runtime, and prove zero residue before considering the level-1 gate.
