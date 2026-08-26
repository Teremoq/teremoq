#!/usr/bin/env bash
set -euo pipefail

if [[ "${TEREMOQ_LAB_ISOLATED:-}" != "1" ]]; then
    echo "Refusing to alter loopback qdisc outside the isolated lab container." >&2
    exit 2
fi

for required in tc; do
    if ! command -v "$required" >/dev/null 2>&1; then
        echo "Missing required lab command: $required" >&2
        exit 2
    fi
done

cleanup() {
    tc qdisc del dev lo root 2>/dev/null || true
}
trap cleanup EXIT INT TERM

tc qdisc replace dev lo root netem \
    delay 35ms 15ms distribution normal \
    loss 3% 25% \
    duplicate 0.1% \
    reorder 10% 50% \
    rate 6mbit \
    limit 1000

export TEREMOQ_LAB_NETEM_PROFILE="delay=35ms+/-15ms;loss=3%/25%;duplicate=0.1%;reorder=10%/50%;rate=6mbit"
export TEREMOQ_LAB_DURATION_SECS="${TEREMOQ_LAB_DURATION_SECS:-300}"
export TEREMOQ_LAB_RATE_HZ="${TEREMOQ_LAB_RATE_HZ:-20}"
export TEREMOQ_LAB_SLOW_DELAY_MS="${TEREMOQ_LAB_SLOW_DELAY_MS:-120}"
export TEREMOQ_LAB_PAYLOAD_BYTES="${TEREMOQ_LAB_PAYLOAD_BYTES:-8192}"

if [[ -n "${TEREMOQ_LAB_TEST_BINARY:-}" ]]; then
    if [[ ! -x "$TEREMOQ_LAB_TEST_BINARY" ]]; then
        echo "Lab test binary is not executable: $TEREMOQ_LAB_TEST_BINARY" >&2
        exit 2
    fi
    "$TEREMOQ_LAB_TEST_BINARY" \
        hostile_network_reconnect_and_soak_remain_bounded \
        --ignored --nocapture
else
    if ! command -v cargo >/dev/null 2>&1; then
        echo "Missing cargo and TEREMOQ_LAB_TEST_BINARY was not provided." >&2
        exit 2
    fi
    cargo test --locked --test moq_relay_interop \
        hostile_network_reconnect_and_soak_remain_bounded \
        -- --ignored --nocapture
fi
