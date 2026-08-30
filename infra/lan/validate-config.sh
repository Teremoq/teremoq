#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Teremoq contributors
# SPDX-License-Identifier: Apache-2.0
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
(( $# == 2 )) && [[ "$1" == --config ]] || lan_die 'usage: validate-config.sh --config ABSOLUTE_TSV'
lan_load_config "$2"
lan_validate_config
printf 'teremoq LAN config: valid; relay activation remains blocked by loopback contract\n'
