#!/usr/bin/env bash
set -Eeuo pipefail

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=../lib.sh
source "${TEST_DIR}/../lib.sh"

fail() {
    printf 'sampling_test: %s\n' "$*" >&2
    exit 1
}

assert_equal() {
    local expected="$1"
    local actual="$2"
    local label="$3"
    [[ "${actual}" == "${expected}" ]] || \
        fail "${label}: expected '${expected}', got '${actual}'"
}

docker() {
    local operation="${1:-}"
    case "${DOCKER_SCENARIO}:${operation}" in
        valid:top|sockets_unobservable:top)
            printf 'PID RSS NLWP COMMAND\n11 1024 2 bash\n12 2048 4 cargo\n'
            ;;
        top_stopped:top)
            printf 'Error response from daemon: container is not running\n' >&2
            return 1
            ;;
        unexpected_text:top)
            printf 'FailedPrecondition: container stopped during request\n'
            ;;
        valid:exec)
            printf '9\n'
            ;;
        sockets_unobservable:exec)
            printf 'Error response from daemon: container is not running\n' >&2
            return 1
            ;;
        *)
            fail "unexpected docker stub invocation: ${DOCKER_SCENARIO}:${operation}"
            ;;
    esac
}

reset_metrics() {
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
}

DOCKER_SCENARIO=valid
sample="$(sample_container runner)" || fail 'numeric sample was rejected'
assert_equal '3072 6 9' "${sample}" 'numeric sample'

DOCKER_SCENARIO=top_stopped
if sample_container runner >/dev/null; then
    fail 'docker top failure was accepted'
fi

DOCKER_SCENARIO=unexpected_text
if sample_container runner >/dev/null; then
    fail 'unexpected textual Docker output was accepted'
fi

DOCKER_SCENARIO=sockets_unobservable
if sample_container runner >/dev/null; then
    fail 'temporarily unobservable sockets were converted into a sample'
fi

reset_metrics
DOCKER_SCENARIO=valid
sample="$(sample_container runner)"
update_sample_metrics "${sample}"
assert_equal 3072 "${rss_final}" 'last valid RSS'
assert_equal 6 "${tasks_final}" 'last valid task count'
assert_equal 9 "${sockets_final}" 'last valid socket count'

DOCKER_SCENARIO=top_stopped
if unavailable_sample="$(sample_container runner)"; then
    update_sample_metrics "${unavailable_sample}"
fi
assert_equal 3072 "${rss_final}" 'RSS preserved after unavailable sample'
assert_equal 6 "${tasks_final}" 'tasks preserved after unavailable sample'
assert_equal 9 "${sockets_final}" 'sockets preserved after unavailable sample'

if update_sample_metrics 'FailedPrecondition: stopped'; then
    fail 'textual state was accepted by the metric updater'
fi
assert_equal 3072 "${rss_final}" 'RSS preserved after rejected text'

printf 'sampling_test: pass\n'
