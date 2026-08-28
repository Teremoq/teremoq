# SPDX-License-Identifier: Apache-2.0
from __future__ import annotations

import json
import tempfile
from contextlib import contextmanager
from pathlib import Path
from typing import Any, Iterator


ROOT = Path(__file__).resolve().parents[1]
CONFIG_PATH = ROOT / "config" / "milestone-100.json"


def raw_config() -> dict[str, Any]:
    return json.loads(CONFIG_PATH.read_text(encoding="utf-8"))


@contextmanager
def temporary_config(value: dict[str, Any]) -> Iterator[Path]:
    with tempfile.TemporaryDirectory() as directory:
        path = Path(directory) / "config.json"
        path.write_text(json.dumps(value), encoding="utf-8")
        yield path
