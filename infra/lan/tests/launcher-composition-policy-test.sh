#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Teremoq contributors
# SPDX-License-Identifier: Apache-2.0
set -Eeuo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
python3 - "${root}" <<'PY'
import pathlib, sys
root = pathlib.Path(sys.argv[1])
wrapper = (root / 'client/Invoke-LanLoad.ps1').read_text()
validation = wrapper.index('Assert-TeremoqLanLauncherStartContract -StateContext $state')
exit_branch = wrapper.index("if ($Action -eq 'Validate') {")
node_probe = wrapper.index('$node = Get-Command node.exe')
assert validation < exit_branch < node_probe, 'Validate bypasses composition or executes Node'
assert '-Action $Action -StateRoot $state.StateRoot' in wrapper
for name in ('Verify-Package.ps1', 'Prepare-LanClientFromGit.ps1'):
    assert 'Assert-TeremoqLanLauncherStartContract -StateContext' in (root/'client'/name).read_text()
library = (root/'client/Client-Distribution.ps1').read_text()
assert 'Get-TeremoqActiveLanClientSlot -StateRoot $StateRoot -ReadOnly' in library
helper = library.split('function Assert-TeremoqLanLauncherStartContract {', 1)[1].split('\nfunction ', 1)[0]
assert '-Action Start -ValidateOnly -StateRoot $StateContext.StateRoot' in helper
assert '-VersionPath $StateContext.VersionPath' in helper
assert '-FingerprintPath $StateContext.FingerprintPath' in helper
assert 'powershell.exe' not in helper and 'Start-Process' not in helper
assert 'New-Item' not in helper and 'CreateDirectory' not in helper
print('launcher composition STATIC wiring: PASS (not real sealed player composition)')
PY
