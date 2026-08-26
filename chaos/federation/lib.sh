#!/usr/bin/env bash

die() {
    printf 'federation chaos: %s\n' "$*" >&2
    exit 2
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

require_uint_between() {
    local name="$1"
    local value="$2"
    local minimum="$3"
    local maximum="$4"
    [[ "${value}" =~ ^[0-9]+$ ]] || die "${name} must be an unsigned integer"
    (( value >= minimum && value <= maximum )) || \
        die "${name} must be between ${minimum} and ${maximum}"
}

load_profile() {
    local profile_path="$1"
    [[ -f "${profile_path}" ]] || die "profile does not exist: ${profile_path}"
    # Profile files are repository-owned constant assignments, not user input.
    # shellcheck disable=SC1090
    source "${profile_path}"

    [[ "${PROFILE_NAME:-}" =~ ^(smoke|hostile)$ ]] || die "invalid PROFILE_NAME"
    [[ "${PROFILE_TOOLCHAIN:-}" =~ ^[A-Za-z0-9._-]+$ ]] || die "invalid PROFILE_TOOLCHAIN"
    [[ "${PROFILE_IMAGE:-}" =~ ^[^[:space:]]+@sha256:[0-9a-f]{64}$ ]] || \
        die "PROFILE_IMAGE must be pinned by sha256 digest"
    require_uint_between PROFILE_SEED "${PROFILE_SEED:-}" 0 4294967295
    require_uint_between PROFILE_GLOBAL_TIMEOUT_SECONDS \
        "${PROFILE_GLOBAL_TIMEOUT_SECONDS:-}" 30 7200
    require_uint_between PROFILE_NETEM_ENABLED "${PROFILE_NETEM_ENABLED:-}" 0 1
    if [[ "${PROFILE_NAME}" == hostile ]]; then
        require_uint_between PROFILE_DURATION_SECONDS "${PROFILE_DURATION_SECONDS:-}" 1 3600
        require_uint_between PROFILE_LOSS_PERCENT "${PROFILE_LOSS_PERCENT:-}" 0 30
        require_uint_between PROFILE_DELAY_MS "${PROFILE_DELAY_MS:-}" 0 5000
        require_uint_between PROFILE_JITTER_MS "${PROFILE_JITTER_MS:-}" 0 5000
        require_uint_between PROFILE_REORDER_PERCENT "${PROFILE_REORDER_PERCENT:-}" 0 30
        require_uint_between PROFILE_SLOW_DELAY_MS "${PROFILE_SLOW_DELAY_MS:-}" 1 10000
        require_uint_between PROFILE_RATE_HZ "${PROFILE_RATE_HZ:-}" 1 1000
        require_uint_between PROFILE_PAYLOAD_BYTES "${PROFILE_PAYLOAD_BYTES:-}" 1024 1048576
        [[ "${PROFILE_RATE:-}" =~ ^[1-9][0-9]*(kbit|mbit)$ ]] || \
            die "PROFILE_RATE is invalid"
        (( PROFILE_NETEM_ENABLED == 1 )) || die "hostile profile must enable netem"
    else
        (( PROFILE_NETEM_ENABLED == 0 )) || die "smoke profile must not enable netem"
    fi
}

preflight() {
    local image="$1"
    for command_name in bash date docker sed awk sort wc ss timeout uname nproc; do
        require_command "${command_name}"
    done
    docker info >/dev/null 2>&1 || die "Docker daemon is unavailable"
    docker image inspect "${image}" >/dev/null 2>&1 || \
        die "pinned image is unavailable locally: ${image}"

    local wall_seconds monotonic_seconds
    wall_seconds="$(date +%s)"
    monotonic_seconds="$(awk '{print $1}' /proc/uptime)"
    [[ "${wall_seconds}" =~ ^[0-9]+$ ]] || die "wall clock is unreadable"
    [[ "${monotonic_seconds}" =~ ^[0-9]+([.][0-9]+)?$ ]] || \
        die "monotonic clock is unreadable"

    # The harness publishes no host ports. Record shared listeners without
    # altering them, so accidental future port publication is review-visible.
    ss -H -lun '( sport = :4433 or sport = :4443 )' >/dev/null 2>&1 || true
}

sample_container() {
    local container_name="$1"
    local top_output resource_sample rss tasks sockets

    if ! top_output="$(docker top "${container_name}" -eo pid,rss,nlwp,comm 2>/dev/null)"; then
        return 1
    fi
    if ! resource_sample="$(
        awk '
            NR == 1 {
                if ($1 != "PID" || $2 != "RSS" || $3 != "NLWP") {
                    exit 2
                }
                next
            }
            {
                if ($1 !~ /^[0-9]+$/ || $2 !~ /^[0-9]+$/ || $3 !~ /^[0-9]+$/) {
                    exit 2
                }
                rss += $2
                tasks += $3
                rows += 1
            }
            END {
                if (rows == 0) {
                    exit 2
                }
                print rss, tasks
            }
        ' <<<"${top_output}"
    )"; then
        return 1
    fi

    if ! sockets="$(
        docker exec "${container_name}" /bin/bash -c \
            'ss -H -a -n 2>/dev/null | wc -l' 2>/dev/null
    )"; then
        return 1
    fi
    if [[ ! "${sockets}" =~ ^[[:space:]]*([0-9]+)[[:space:]]*$ ]]; then
        return 1
    fi
    sockets="${BASH_REMATCH[1]}"

    if [[ ! "${resource_sample} ${sockets}" =~ ^([0-9]+)[[:space:]]([0-9]+)[[:space:]]([0-9]+)$ ]]; then
        return 1
    fi
    rss="${BASH_REMATCH[1]}"
    tasks="${BASH_REMATCH[2]}"
    sockets="${BASH_REMATCH[3]}"
    printf '%s %s %s\n' "${rss}" "${tasks}" "${sockets}"
}

update_sample_metrics() {
    local sample="$1"
    local rss tasks sockets

    if [[ ! "${sample}" =~ ^([0-9]+)[[:space:]]([0-9]+)[[:space:]]([0-9]+)$ ]]; then
        return 1
    fi
    rss="${BASH_REMATCH[1]}"
    tasks="${BASH_REMATCH[2]}"
    sockets="${BASH_REMATCH[3]}"

    if [[ "${sampled}" -eq 0 ]]; then
        rss_initial="${rss}"
        tasks_initial="${tasks}"
        sockets_initial="${sockets}"
        sampled=1
    fi
    rss_final="${rss}"
    tasks_final="${tasks}"
    sockets_final="${sockets}"
    if [[ "${rss_peak}" == unavailable ]] || ((rss > rss_peak)); then
        rss_peak="${rss}"
    fi
    if [[ "${tasks_peak}" == unavailable ]] || ((tasks > tasks_peak)); then
        tasks_peak="${tasks}"
    fi
    if [[ "${sockets_peak}" == unavailable ]] || ((sockets > sockets_peak)); then
        sockets_peak="${sockets}"
    fi
}

render_report() {
    local report_path="$1"
    local log_path="$2"
    local exit_code="$3"
    local cleanup_ok="$4"
    local rss_initial="$5"
    local rss_peak="$6"
    local rss_final="$7"
    local tasks_initial="$8"
    local tasks_peak="$9"
    local tasks_final="${10}"
    local sockets_initial="${11}"
    local sockets_peak="${12}"
    local sockets_final="${13}"
    local started_utc="${14}"
    local finished_utc="${15}"
    local unavailable_samples="${16}"
    local after_cleanup=unavailable
    if [[ "${cleanup_ok}" == true ]]; then
        after_cleanup=0
    fi

    {
        printf '# Federation concurrency report\n\n'
        printf -- '- Schema version: 2\n'
        printf -- '- Result: `%s`\n' "$( (( exit_code == 0 )) && printf pass || printf fail )"
        printf -- '- Started UTC: `%s`\n' "${started_utc}"
        printf -- '- Finished UTC: `%s`\n' "${finished_utc}"
        printf -- '- Workspace revision: `metadata unavailable (workspace has no .git)`\n'
        printf -- '- moq-rs revision: `bf87128affd316463e5dcc7599a45001f222b6de`\n'
        printf -- '- Kernel: `%s`\n' "$(uname -srmo)"
        printf -- '- Docker: `%s`\n' "$(docker version --format '{{.Server.Version}}' 2>/dev/null || printf unavailable)"
        printf -- '- Toolchain: `%s`\n' "${PROFILE_TOOLCHAIN}"
        printf -- '- CPU logical: `%s`\n' "$(nproc)"
        printf -- '- Memory available before run KiB: `%s`\n' \
            "$(awk '/MemAvailable:/ {print $2}' /proc/meminfo)"
        printf -- '- Profile: `%s`; seed: `%s`; network case: `%s`\n' \
            "${PROFILE_NAME}" "${PROFILE_SEED}" "${network_case}"
        printf -- '- Image: `%s`\n' "${PROFILE_IMAGE}"
        printf '\n## Requested and consumed configuration\n\n'
        if [[ "${PROFILE_NAME}" == smoke ]]; then
            printf -- '- Requested: fixed hermetic Rust cases. Peer count is emitted by Rust per identity type.\n'
            printf -- '- Consumed: federation identity matrix, one mTLS/MoQT isolation case, simple relay interop, and the multi-Object Subgroup reader regression.\n'
            printf -- '- Duration, publish rate, payload size, slow-reader delay, `PROFILE_PEERS`, and netem: `not_applicable`.\n'
        else
            printf -- '- Requested workload: duration `%ss`, rate `%s Objects/s`, payload `%s bytes`, slow-reader delay `%sms`.\n' \
                "${PROFILE_DURATION_SECONDS}" "${PROFILE_RATE_HZ}" \
                "${PROFILE_PAYLOAD_BYTES}" "${PROFILE_SLOW_DELAY_MS}"
            printf -- '- Consumed workload: the same four validated values were passed to and parsed by the Rust hostile test.\n'
            printf -- '- Requested combined netem profile: loss `%s%%`, delay `%sms +/- %sms`, reorder `%s%%`, rate `%s`.\n' \
                "${PROFILE_LOSS_PERCENT}" "${PROFILE_DELAY_MS}" "${PROFILE_JITTER_MS}" \
                "${PROFILE_REORDER_PERCENT}" "${PROFILE_RATE}"
            printf -- '- Consumed network case `%s`: loss `%s%%`, delay `%sms +/- %sms`, reorder `%s%%`, rate `%s`.\n' \
                "${network_case}" "${effective_loss_percent}" "${effective_delay_ms}" \
                "${effective_jitter_ms}" "${effective_reorder_percent}" "${effective_rate}"
            printf -- '- `PROFILE_PEERS`: `not_applicable`; actual topology is emitted by Rust (one relay, one publisher, one fast and one slow subscriber).\n'
        fi
        printf '\n## Limits and observability\n\n'
        printf -- '- Relay handshake capacity: **unenforced**; relay session capacity: **unenforced**\n'
        printf -- '- Controlled scheduler limit actually applied: `2 subscribers; 1 Object and 1024 bytes per subscriber`\n'
        printf -- '- A truly pending QUIC/TLS handshake: `untestable_with_pinned_public_api`\n'
        printf -- '- Pending handshake and relay Tokio task counts: **unobservable with pinned public API**\n'
        printf -- '- `transport_connect` includes QUIC, TLS, and WebTransport CONNECT in the pinned client API.\n\n'
        printf -- '- Relay accepted/rejected/closed totals by reason: **unobservable with pinned public API**; finite client scenarios are in the Rust result\n'
        printf -- '- Phase-specific timings and their sample counts are in the Rust result; heterogeneous phases are not combined into percentiles.\n\n'
        printf '| Metric | Initial | Peak | Final before container exit | After cleanup |\n'
        printf '| --- | ---: | ---: | ---: | ---: |\n'
        printf '| Aggregate process RSS KiB | %s | %s | %s | %s |\n' \
            "${rss_initial}" "${rss_peak}" "${rss_final}" "${after_cleanup}"
        printf '| OS tasks/threads | %s | %s | %s | %s |\n' \
            "${tasks_initial}" "${tasks_peak}" "${tasks_final}" "${after_cleanup}"
        printf '| Sockets | %s | %s | %s | %s |\n' \
            "${sockets_initial}" "${sockets_peak}" "${sockets_final}" "${after_cleanup}"
        printf '\nSampler unavailable observations: `%s`.\n' "${unavailable_samples}"
        printf '\nCleanup verified: `%s`. Exit code: `%s`.\n\n' "${cleanup_ok}" "${exit_code}"
        printf 'The Rust result below contains phase-specific transport/MoQT timings, rejection reasons, '
        printf 'valid-peer progress, Objects for the selected video-only relay lab, and scheduler counters. '
        printf 'Unavailable fields remain explicit; this finite run is not evidence of a production bound or leak freedom.\n\n'
        printf '```text\n'
        sed -E 's#(/tmp|/workspace)/[^[:space:]"`]+#[REDACTED_PATH]#g' "${log_path}"
        printf '```\n'
    } >"${report_path}"
}
