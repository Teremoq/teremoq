<!-- SPDX-FileCopyrightText: 2026 Teremoq contributors -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# Task 10 third-party boundary

Task 10 adds no package, crate, binary or downloaded image. The optional local
Compose smoke reuses the existing Step 7 laboratory image already recorded by
the federation Chaos harness:

```text
teremoq-step7-lab:rust-1.93-full
sha256:ba076cf0a26aa41efdd2f0f80687ef97009d1526680751456c19cc944dff1d0b
```

`pull_policy: never` makes absence a local preflight failure; the harness never
downloads a substitute. The image is a development/test artifact based on the
official Rust 1.93 Bookworm toolchain and is not added to a product appliance
or release by this task. Its prior inventory does not replace a fresh
`TP-OSS-SC` artifact review if this virtual-node lab is later distributed.

The scripts use only Bash, GNU core utilities, Docker Engine and Docker Compose
already present on the host. No cloud SDK, provider client, traffic simulator,
media client or telemetry dependency is introduced.
