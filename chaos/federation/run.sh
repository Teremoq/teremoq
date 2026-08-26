#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd -P)"
GATEWAY_ROOT="${REPO_ROOT}/gateway-rs"
REPORT_DIR="${SCRIPT_DIR}/reports"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

profile=smoke
soak=0
network_case=combined
network_case_explicit=0
while (( $# > 0 )); do
    case "$1" in
        --profile)
            (( $# >= 2 )) || die "--profile requires smoke or hostile"
            profile="$2"
            shift 2
            ;;
        --soak)
            soak=1
            shift
            ;;
        --network-case)
            (( $# >= 2 )) || die "--network-case requires baseline, delay, loss, reorder, bandwidth, or combined"
            network_case="$2"
            network_case_explicit=1
            shift 2
            ;;
        *) die "unknown argument: $1" ;;
    esac
done
[[ "${profile}" =~ ^(smoke|hostile)$ ]] || die "profile must be smoke or hostile"
(( soak == 0 )) || [[ "${profile}" == hostile ]] || \
    die "--soak is valid only with --profile hostile"
[[ "${network_case}" =~ ^(baseline|delay|loss|reorder|bandwidth|combined)$ ]] || \
    die "invalid --network-case"
(( network_case_explicit == 0 )) || [[ "${profile}" == hostile ]] || \
    die "--network-case is valid only with --profile hostile"

load_profile "${SCRIPT_DIR}/profiles/${profile}.env"
if [[ "${profile}" == smoke ]]; then
    network_case=not_applicable
fi
if (( soak == 1 )); then
    PROFILE_DURATION_SECONDS="${TEREMOQ_FEDERATION_SOAK_SECONDS:-1800}"
    require_uint_between TEREMOQ_FEDERATION_SOAK_SECONDS \
        "${PROFILE_DURATION_SECONDS}" 300 3600
    PROFILE_GLOBAL_TIMEOUT_SECONDS=$(( PROFILE_DURATION_SECONDS + 180 ))
fi

effective_netem_enabled=0
effective_loss_percent=not_applicable
effective_delay_ms=not_applicable
effective_jitter_ms=not_applicable
effective_reorder_percent=not_applicable
effective_rate=not_applicable
netem_args=()
if [[ "${profile}" == hostile ]]; then
    effective_loss_percent=0
    effective_delay_ms=0
    effective_jitter_ms=0
    effective_reorder_percent=0
    effective_rate=unlimited
    case "${network_case}" in
        baseline) ;;
        delay)
            effective_netem_enabled=1
            effective_delay_ms="${PROFILE_DELAY_MS}"
            effective_jitter_ms="${PROFILE_JITTER_MS}"
            netem_args+=(delay "${PROFILE_DELAY_MS}ms" "${PROFILE_JITTER_MS}ms" distribution normal)
            ;;
        loss)
            effective_netem_enabled=1
            effective_loss_percent="${PROFILE_LOSS_PERCENT}"
            netem_args+=(loss "${PROFILE_LOSS_PERCENT}%")
            ;;
        reorder)
            effective_netem_enabled=1
            # netem needs a non-zero queueing delay in order to reorder packets.
            effective_delay_ms=1
            effective_jitter_ms=0
            effective_reorder_percent="${PROFILE_REORDER_PERCENT}"
            netem_args+=(delay 1ms 0ms reorder "${PROFILE_REORDER_PERCENT}%" 50%)
            ;;
        bandwidth)
            effective_netem_enabled=1
            effective_rate="${PROFILE_RATE}"
            netem_args+=(rate "${PROFILE_RATE}")
            ;;
        combined)
            effective_netem_enabled=1
            effective_loss_percent="${PROFILE_LOSS_PERCENT}"
            effective_delay_ms="${PROFILE_DELAY_MS}"
            effective_jitter_ms="${PROFILE_JITTER_MS}"
            effective_reorder_percent="${PROFILE_REORDER_PERCENT}"
            effective_rate="${PROFILE_RATE}"
            netem_args+=(
                delay "${PROFILE_DELAY_MS}ms" "${PROFILE_JITTER_MS}ms" distribution normal
                loss "${PROFILE_LOSS_PERCENT}%"
                reorder "${PROFILE_REORDER_PERCENT}%" 50%
                rate "${PROFILE_RATE}"
            )
            ;;
    esac
    if (( effective_netem_enabled == 1 )); then
        netem_args+=(limit 1000)
    fi
fi
preflight "${PROFILE_IMAGE}"

mkdir -p -- "${REPORT_DIR}"
run_id="teremoq-federation-${profile}-${network_case}-$$-${RANDOM}"
network_name="${run_id}-net"
container_name="${run_id}-runner"
scratch="$(mktemp -d /tmp/teremoq-federation.XXXXXX)"
log_path="${scratch}/run.log"
cleanup_ok=false
container_created=0
network_created=0
signal_exit_code=0

cleanup() {
    local cleanup_status=0
    if (( container_created == 1 )); then
        if (( effective_netem_enabled == 1 )); then
            docker exec "${container_name}" tc qdisc del dev lo root >/dev/null 2>&1 || true
        fi
        if docker rm -f "${container_name}" >/dev/null 2>&1; then
            container_created=0
        else
            cleanup_status=1
        fi
    fi
    if (( network_created == 1 )); then
        if docker network rm "${network_name}" >/dev/null 2>&1; then
            network_created=0
        else
            cleanup_status=1
        fi
    fi
    if ! docker ps -a --format '{{.Names}}' | awk -v name="${container_name}" '$0 == name {found=1} END {exit found ? 0 : 1}'; then
        if ! docker network inspect "${network_name}" >/dev/null 2>&1; then
            cleanup_ok=true
        fi
    fi
    return "${cleanup_status}"
}
finish() {
    cleanup || true
    rm -rf -- "${scratch}"
}
handle_signal() {
    signal_exit_code="$1"
    if (( container_created == 1 )); then
        docker stop --time 5 "${container_name}" >/dev/null 2>&1 || true
    fi
}
trap finish EXIT
trap 'handle_signal 130' INT
trap 'handle_signal 143' TERM

docker network create --driver bridge --label teremoq.federation.run="${run_id}" \
    "${network_name}" >/dev/null
network_created=1

container_args=(
    run --detach --name "${container_name}"
    --network "${network_name}"
    --label "teremoq.federation.run=${run_id}"
    --pids-limit 512
    --memory 2g
    --cpus 4
    --security-opt no-new-privileges:true
    --volume "${GATEWAY_ROOT}:/workspace"
    --workdir /workspace
    --env RUSTUP_TOOLCHAIN=1.93.0-x86_64-unknown-linux-gnu
)
if [[ "${profile}" == hostile ]]; then
    container_args+=(
        --env TEREMOQ_LAB_DURATION_SECS="${PROFILE_DURATION_SECONDS}"
        --env TEREMOQ_LAB_RATE_HZ="${PROFILE_RATE_HZ}"
        --env TEREMOQ_LAB_SLOW_DELAY_MS="${PROFILE_SLOW_DELAY_MS}"
        --env TEREMOQ_LAB_PAYLOAD_BYTES="${PROFILE_PAYLOAD_BYTES}"
        --env TEREMOQ_LAB_NETEM_PROFILE="federation-${PROFILE_NAME}-${network_case}-seed-${PROFILE_SEED}"
    )
fi
if (( effective_netem_enabled == 1 )); then
    container_args+=(--cap-add NET_ADMIN)
fi

if [[ "${profile}" == hostile ]]; then
    hostile_tests="cargo test --locked --test federation_concurrency -- --nocapture; cargo test --locked --test moq_relay_interop hostile_network_reconnect_and_finite_video_progress -- --ignored --nocapture"
    if (( effective_netem_enabled == 1 )); then
        printf -v netem_spec '%q ' "${netem_args[@]}"
        command_body="trap 'tc qdisc del dev lo root >/dev/null 2>&1 || true' EXIT INT TERM; tc qdisc replace dev lo root netem ${netem_spec}; ${hostile_tests}"
    else
        command_body="${hostile_tests}"
    fi
else
    command_body="cargo test --locked --test federation_concurrency -- --nocapture; cargo test --locked --test mtls_quic valid_clients_progress_while_invalid_transport_connects_and_delayed_moqt_setup_are_isolated -- --nocapture; cargo test --locked --test moq_relay_interop -- --nocapture"
fi

started_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
docker "${container_args[@]}" "${PROFILE_IMAGE}" /bin/bash -c "${command_body}" >/dev/null
container_created=1
port_bindings="$(docker inspect --format '{{json .HostConfig.PortBindings}}' "${container_name}")"
if [[ "${port_bindings}" != "null" && "${port_bindings}" != "{}" ]]; then
    die "runner unexpectedly publishes host ports"
fi

rss_initial=unavailable
rss_peak=unavailable
rss_final=unavailable
tasks_initial=unavailable
tasks_peak=unavailable
tasks_final=unavailable
sockets_initial=unavailable
sockets_peak=unavailable
sockets_final=unavailable
sampled=0
unavailable_samples=0
timed_out=0
while true; do
    if ! running_state="$(
        docker inspect --format '{{.State.Running}}' "${container_name}" 2>/dev/null
    )"; then
        break
    fi
    [[ "${running_state}" == true ]] || break
    if sample="$(sample_container "${container_name}")"; then
        if ! update_sample_metrics "${sample}"; then
            unavailable_samples=$((unavailable_samples + 1))
        fi
    else
        unavailable_samples=$((unavailable_samples + 1))
    fi
    if (( SECONDS >= PROFILE_GLOBAL_TIMEOUT_SECONDS )); then
        timed_out=1
        docker stop --time 5 "${container_name}" >/dev/null 2>&1 || true
        break
    fi
    if ! sleep 1; then
        (( signal_exit_code != 0 )) && break
        die "sampler sleep failed"
    fi
done

docker logs "${container_name}" >"${log_path}" 2>&1 || true
if ! exit_code="$(
    docker inspect --format '{{.State.ExitCode}}' "${container_name}" 2>/dev/null
)" || [[ ! "${exit_code}" =~ ^[0-9]+$ ]]; then
    printf 'unable to collect the container exit code\n' >>"${log_path}"
    exit_code=125
fi
(( timed_out == 0 )) || exit_code=124
(( signal_exit_code == 0 )) || exit_code="${signal_exit_code}"
cleanup || true
finished_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
report_path="${REPORT_DIR}/${profile}-${network_case}-$(date -u +%Y%m%dT%H%M%SZ)-seed-${PROFILE_SEED}.md"
render_report "${report_path}" "${log_path}" "${exit_code}" "${cleanup_ok}" \
    "${rss_initial}" "${rss_peak}" "${rss_final}" \
    "${tasks_initial}" "${tasks_peak}" "${tasks_final}" \
    "${sockets_initial}" "${sockets_peak}" "${sockets_final}" \
    "${started_utc}" "${finished_utc}" "${unavailable_samples}"

printf 'report=%s\n' "${report_path}"
printf 'result=%s cleanup=%s\n' "$( (( exit_code == 0 )) && printf pass || printf fail )" "${cleanup_ok}"
(( exit_code == 0 ))
