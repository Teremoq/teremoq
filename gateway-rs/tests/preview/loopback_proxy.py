#!/usr/bin/env python3
"""Expose loopback-only development services through explicit container ports."""

import argparse
import select
import selectors
import socket
import threading
import time


MAX_UDP_CLIENTS = 64
UDP_CLIENT_IDLE_SECONDS = 30.0


def copy_bidirectional(client: socket.socket, backend_port: int) -> None:
    try:
        with client, socket.create_connection(("127.0.0.1", backend_port)) as backend:
            sockets = [client, backend]
            while True:
                readable, _, _ = select.select(sockets, [], [], 30)
                if not readable:
                    continue
                for source in readable:
                    payload = source.recv(65536)
                    if not payload:
                        return
                    destination = backend if source is client else client
                    destination.sendall(payload)
    except OSError:
        return


def run_tcp(front_port: int, backend_port: int) -> None:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
        listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        listener.bind(("0.0.0.0", front_port))
        listener.listen(32)
        while True:
            client, _ = listener.accept()
            threading.Thread(
                target=copy_bidirectional,
                args=(client, backend_port),
                daemon=True,
            ).start()


def run_udp(front_port: int, backend_port: int) -> None:
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as frontend:
        frontend.bind(("0.0.0.0", front_port))
        frontend.setblocking(False)
        selector = selectors.DefaultSelector()
        selector.register(frontend, selectors.EVENT_READ, None)
        backends: dict[tuple[str, int], socket.socket] = {}
        last_activity: dict[tuple[str, int], float] = {}

        def close_client(client: tuple[str, int]) -> None:
            backend = backends.pop(client, None)
            last_activity.pop(client, None)
            if backend is None:
                return
            try:
                selector.unregister(backend)
            except (KeyError, ValueError):
                pass
            backend.close()

        def backend_for(client: tuple[str, int]) -> socket.socket:
            existing = backends.get(client)
            if existing is not None:
                return existing
            if len(backends) >= MAX_UDP_CLIENTS:
                oldest = min(last_activity, key=last_activity.__getitem__)
                close_client(oldest)
            backend = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            backend.connect(("127.0.0.1", backend_port))
            backend.setblocking(False)
            backends[client] = backend
            last_activity[client] = time.monotonic()
            selector.register(backend, selectors.EVENT_READ, client)
            return backend

        try:
            while True:
                for key, _ in selector.select(timeout=1.0):
                    if key.data is None:
                        payload, client = frontend.recvfrom(65535)
                        try:
                            backend_for(client).send(payload)
                            last_activity[client] = time.monotonic()
                        except OSError:
                            close_client(client)
                    else:
                        client = key.data
                        backend = key.fileobj
                        try:
                            payload = backend.recv(65535)
                            frontend.sendto(payload, client)
                            last_activity[client] = time.monotonic()
                        except OSError:
                            close_client(client)

                cutoff = time.monotonic() - UDP_CLIENT_IDLE_SECONDS
                for client, last_seen in list(last_activity.items()):
                    if last_seen < cutoff:
                        close_client(client)
        finally:
            for client in list(backends):
                close_client(client)
            selector.close()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--tcp-front", type=int, required=True)
    parser.add_argument("--tcp-back", type=int, required=True)
    parser.add_argument("--udp-front", type=int, required=True)
    parser.add_argument("--udp-back", type=int, required=True)
    args = parser.parse_args()
    threading.Thread(
        target=run_tcp,
        args=(args.tcp_front, args.tcp_back),
        daemon=True,
    ).start()
    run_udp(args.udp_front, args.udp_back)


if __name__ == "__main__":
    main()
