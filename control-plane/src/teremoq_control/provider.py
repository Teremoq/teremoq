# SPDX-License-Identifier: Apache-2.0
"""Provider-neutral capacity interface and the only permitted local adapter."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Protocol

from .model import Action, Lifecycle


@dataclass(frozen=True, slots=True)
class ProviderTransition:
    node_id: str
    generation: int
    state: Lifecycle


class CapacityProvider(Protocol):
    """Provider contract. Production adapters are intentionally out of scope."""

    def plan(self, actions: tuple[Action, ...]) -> tuple[Action, ...]: ...

    def apply(self, actions: tuple[Action, ...]) -> tuple[ProviderTransition, ...]: ...

    def destroy(self, actions: tuple[Action, ...]) -> tuple[ProviderTransition, ...]: ...


class LocalSimulatorProvider:
    """Deterministic adapter with no network, subprocess, or provider calls."""

    def __init__(self, mode: str) -> None:
        if mode not in {"simulate", "dry-run"}:
            raise ValueError("local simulator supports only simulate or dry-run")
        self.mode = mode

    def plan(self, actions: tuple[Action, ...]) -> tuple[Action, ...]:
        return actions

    def apply(self, actions: tuple[Action, ...]) -> tuple[ProviderTransition, ...]:
        if self.mode == "dry-run":
            return ()
        transitions: list[ProviderTransition] = []
        for action in actions:
            if action.operation != "create":
                continue
            for state in (
                Lifecycle.PROVISIONING,
                Lifecycle.BOOTSTRAPPING,
                Lifecycle.AUTHENTICATED,
                Lifecycle.REGISTERED,
                Lifecycle.READY,
            ):
                transitions.append(ProviderTransition(action.node_id, action.generation, state))
        return tuple(transitions)

    def destroy(self, actions: tuple[Action, ...]) -> tuple[ProviderTransition, ...]:
        if self.mode == "dry-run":
            return ()
        transitions: list[ProviderTransition] = []
        for action in actions:
            if action.operation != "destroy":
                continue
            transitions.append(ProviderTransition(action.node_id, action.generation, Lifecycle.DRAINING))
            transitions.append(ProviderTransition(action.node_id, action.generation, Lifecycle.TERMINATED))
        return tuple(transitions)
