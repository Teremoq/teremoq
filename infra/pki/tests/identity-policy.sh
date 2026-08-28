#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PKI_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd -P)"
REPO_ROOT="$(cd -- "${PKI_ROOT}/../.." && pwd -P)"
# shellcheck disable=SC1091
source "${PKI_ROOT}/versions.env"
: "${STEP_CA_IMAGE:?STEP_CA_IMAGE is required}"
: "${STEP_CLI_IMAGE:?STEP_CLI_IMAGE is required}"
if (( $# != 0 )); then echo "identity-policy.sh accepts no arguments" >&2; exit 64; fi

python3 - "${PKI_ROOT}/config/identity-policy.json" <<'PY'
import copy
import json
import re
import sys
from pathlib import Path

policy_path = Path(sys.argv[1])
policy = json.loads(policy_path.read_text(encoding="utf-8"))

expected = {
    "schemaVersion": 1,
    "environment": "development-integration-ci",
    "defaultDecision": "deny",
    "identity": {
        "trustDomain": "teremoq.local",
        "nodeIdPattern": r"^[A-Za-z0-9._-]{1,64}$",
        "requiredUriSanCount": 1,
        "gatewayUriPattern": "spiffe://teremoq.local/gateway/<node-id>",
        "relayUriPattern": "spiffe://teremoq.local/relay/<node-id>",
        "allowedSanTypes": {
            "gateway": ["uri"],
            "relay": ["uri", "dns", "ip"],
        },
    },
    "certificateLimits": {
        "maxChainCertificates": 8,
        "maxLeafDerBytes": 16_384,
        "maxChainDerBytes": 65_536,
    },
    "connection": {"requiredPath": "/publish"},
    "principals": {
        "gateway-dev-1": {
            "uri": "spiffe://teremoq.local/gateway/gateway-dev-1",
            "role": "gateway",
            "allow": [
                {"operation": "Publish", "namespace": "teremoq/live"},
                {"operation": "PublishNamespace", "namespace": "teremoq/live"},
            ],
        }
    },
    "roles": {"relay": {"defaultDecision": "deny", "allow": []}},
}

def validates(candidate):
    return candidate == expected


if not validates(policy):
    raise SystemExit("identity policy does not match the approved fail-closed contract")

node_id = re.compile(policy["identity"]["nodeIdPattern"], re.ASCII)


def parse_identity(uri: str):
    prefix = "spiffe://teremoq.local/"
    if not uri.startswith(prefix) or "%" in uri or any(ord(ch) > 127 for ch in uri):
        return None
    suffix = uri[len(prefix):]
    parts = suffix.split("/")
    if len(parts) != 2 or parts[0] not in {"gateway", "relay"}:
        return None
    if node_id.fullmatch(parts[1]) is None or parts[1] in {".", ".."}:
        return None
    if uri != f"{prefix}{parts[0]}/{parts[1]}":
        return None
    return parts[0], parts[1]


def authorize(uri: str, operation: str, namespace: str, path: str) -> bool:
    identity = parse_identity(uri)
    if identity is None or path != policy["connection"]["requiredPath"]:
        return False
    role, principal_id = identity
    if role == "relay":
        return False
    principal = policy["principals"].get(principal_id)
    if principal is None or principal["role"] != role or principal["uri"] != uri:
        return False
    return {"operation": operation, "namespace": namespace} in principal["allow"]


positive = [
    ("spiffe://teremoq.local/gateway/gateway-dev-1", "Publish", "teremoq/live", "/publish"),
    ("spiffe://teremoq.local/gateway/gateway-dev-1", "PublishNamespace", "teremoq/live", "/publish"),
]
for case in positive:
    if not authorize(*case):
        raise SystemExit("approved gateway decision was denied")

negative = [
    ("spiffe://teremoq.local/gateway/gateway-dev-2", "Publish", "teremoq/live", "/publish"),
    ("spiffe://teremoq.local/gateway/gateway-dev-1", "Publish", "teremoq/live/extra", "/publish"),
    ("spiffe://teremoq.local/gateway/gateway-dev-1", "Publish", "teremoq/live", "/other"),
    ("spiffe://teremoq.local/gateway/gateway-dev-1", "Subscribe", "teremoq/live", "/publish"),
    ("spiffe://teremoq.local/gateway/gateway-dev-1", "SubscribeNamespace", "teremoq/live", "/publish"),
    ("spiffe://teremoq.local/gateway/gateway-dev-1", "DiscoverNamespace", "teremoq/live", "/publish"),
    ("spiffe://teremoq.local/gateway/gateway-dev-1", "TrackStatus", "teremoq/live", "/publish"),
    ("spiffe://teremoq.local/gateway/gateway-dev-1", "RelayPeer(Publish)", "teremoq/live", "/publish"),
    ("spiffe://teremoq.local/relay/relay-dev-1", "Publish", "teremoq/live", "/publish"),
    ("spiffe://other.local/gateway/gateway-dev-1", "Publish", "teremoq/live", "/publish"),
    ("spiffe://teremoq.local/Gateway/gateway-dev-1", "Publish", "teremoq/live", "/publish"),
    ("spiffe://teremoq.local/gateway/../gateway-dev-1", "Publish", "teremoq/live", "/publish"),
    ("spiffe://teremoq.local/gateway/gateway%2ddev-1", "Publish", "teremoq/live", "/publish"),
    ("spiffe://teremoq.local/gateway/gateway-dev-1?admin", "Publish", "teremoq/live", "/publish"),
]
for case in negative:
    if authorize(*case):
        raise SystemExit("default-deny decision was incorrectly allowed")


def chain_within_limits(lengths):
    limits = policy["certificateLimits"]
    if not lengths or len(lengths) > limits["maxChainCertificates"]:
        return False
    if lengths[0] <= 0 or lengths[0] > limits["maxLeafDerBytes"]:
        return False
    total = 0
    for length in lengths:
        if length <= 0 or total > limits["maxChainDerBytes"] - length:
            return False
        total += length
    return total <= limits["maxChainDerBytes"]


for lengths in ([1], [16_384], [8_192] * 8, [16_384] + [7_022] * 6 + [7_020]):
    if not chain_within_limits(lengths):
        raise SystemExit("certificate-chain boundary was incorrectly denied")
for lengths in ([], [0], [16_385], [1] * 9, [16_384] + [7_022] * 6 + [7_021]):
    if chain_within_limits(lengths):
        raise SystemExit("certificate-chain limit was incorrectly allowed")

for mutation in (
    ("defaultDecision", "allow"),
    ("relayDefault", "allow"),
    ("trustDomain", "other.local"),
    ("requiredUriSanCount", 2),
    ("gatewayAllow", "Subscribe"),
    ("maxChainCertificates", 9),
    ("maxLeafDerBytes", 16_385),
    ("maxChainDerBytes", 65_537),
):
    altered = copy.deepcopy(policy)
    key, value = mutation
    if key == "relayDefault":
        altered["roles"]["relay"]["defaultDecision"] = value
    elif key == "trustDomain":
        altered["identity"]["trustDomain"] = value
    elif key == "requiredUriSanCount":
        altered["identity"]["requiredUriSanCount"] = value
    elif key == "gatewayAllow":
        altered["principals"]["gateway-dev-1"]["allow"].append(
            {"operation": value, "namespace": "teremoq/live"}
        )
    elif key in altered["certificateLimits"]:
        altered["certificateLimits"][key] = value
    else:
        altered[key] = value
    if validates(altered):
        raise SystemExit("policy mutation was not detected")

print("Identity policy contract passed")
PY
