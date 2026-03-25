#!/usr/bin/env python3
import argparse
import json
import socket
import sys
from pathlib import Path
from typing import Any


REPO_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_PORT_FILE = REPO_ROOT / ".nrepl-port"


class BencodeNeedMoreData(Exception):
    pass


class BencodeError(ValueError):
    pass


def encode_bytes(value: bytes) -> bytes:
    return str(len(value)).encode("ascii") + b":" + value


def encode_value(value: Any) -> bytes:
    if isinstance(value, int):
        return b"i" + str(value).encode("ascii") + b"e"
    if isinstance(value, str):
        return encode_bytes(value.encode("utf-8"))
    if isinstance(value, (bytes, bytearray)):
        return encode_bytes(bytes(value))
    if isinstance(value, list):
        return b"l" + b"".join(encode_value(item) for item in value) + b"e"
    if isinstance(value, tuple):
        return b"l" + b"".join(encode_value(item) for item in value) + b"e"
    if isinstance(value, dict):
        items: list[bytes] = []
        for key, inner in value.items():
            if not isinstance(key, str):
                raise TypeError("dictionary keys must be strings")
            items.append(encode_bytes(key.encode("utf-8")))
            items.append(encode_value(inner))
        return b"d" + b"".join(items) + b"e"
    raise TypeError(f"unsupported bencode value type: {type(value)!r}")


def decode_value(data: bytes, index: int = 0) -> tuple[Any, int]:
    if index >= len(data):
        raise BencodeNeedMoreData

    marker = data[index:index + 1]
    if marker == b"i":
        end = data.find(b"e", index + 1)
        if end == -1:
            raise BencodeNeedMoreData
        return int(data[index + 1:end]), end + 1

    if marker == b"l":
        items: list[Any] = []
        cursor = index + 1
        while True:
            if cursor >= len(data):
                raise BencodeNeedMoreData
            if data[cursor:cursor + 1] == b"e":
                return items, cursor + 1
            item, cursor = decode_value(data, cursor)
            items.append(item)

    if marker == b"d":
        values: dict[bytes, Any] = {}
        cursor = index + 1
        while True:
            if cursor >= len(data):
                raise BencodeNeedMoreData
            if data[cursor:cursor + 1] == b"e":
                return values, cursor + 1
            key, cursor = decode_value(data, cursor)
            if not isinstance(key, bytes):
                raise BencodeError("dictionary key must be bytes")
            value, cursor = decode_value(data, cursor)
            values[key] = value

    if b"0" <= marker <= b"9":
        colon = data.find(b":", index)
        if colon == -1:
            raise BencodeNeedMoreData
        try:
            size = int(data[index:colon])
        except ValueError as exc:
            raise BencodeError("invalid string size") from exc
        start = colon + 1
        end = start + size
        if end > len(data):
            raise BencodeNeedMoreData
        return data[start:end], end

    raise BencodeError(f"invalid bencode marker {marker!r}")


def decode_bytes(value: bytes) -> Any:
    try:
        return value.decode("utf-8")
    except UnicodeDecodeError:
        return list(value)


def to_jsonable(value: Any) -> Any:
    if isinstance(value, bytes):
        return decode_bytes(value)
    if isinstance(value, list):
        return [to_jsonable(item) for item in value]
    if isinstance(value, dict):
        return {decode_bytes(key): to_jsonable(inner) for key, inner in value.items()}
    return value


def resolve_path(text: str) -> str:
    path = Path(text)
    if path.is_absolute():
        return str(path)

    candidates = (
        Path.cwd() / path,
        REPO_ROOT / path,
    )
    for candidate in candidates:
        if candidate.exists():
            return str(candidate.resolve())

    return text


def parse_key_value(entries: list[str], flag_name: str) -> list[tuple[str, str]]:
    pairs: list[tuple[str, str]] = []
    for entry in entries:
        if "=" not in entry:
            raise SystemExit(f"{flag_name} expects KEY=VALUE entries: {entry!r}")
        key, value = entry.split("=", 1)
        if not key:
            raise SystemExit(f"{flag_name} entry has empty key: {entry!r}")
        pairs.append((key, value))
    return pairs


def build_request(args: argparse.Namespace) -> bytes:
    if args.op is None:
        raise SystemExit("--op is required")
    if args.op == "eval" and args.code is None:
        raise SystemExit("--op eval requires --code")
    if args.op == "load-file" and args.file_path is None:
        raise SystemExit("--op load-file requires --file-path")
    if args.op == "in-file" and args.path is None:
        raise SystemExit("--op in-file requires --path")

    request: dict[str, Any] = {
        "op": args.op,
        "session": args.session,
    }

    if args.scope is not None:
        request["scope"] = args.scope
    if args.generation is not None:
        request["generation"] = args.generation
    if args.path is not None:
        request["path"] = resolve_path(args.path)
    if args.code is not None:
        request["code"] = sys.stdin.read() if args.code == "-" else args.code

    for key, value in parse_key_value(args.field, "--field"):
        request[key] = value
    for key, value in parse_key_value(args.int_field, "--int-field"):
        request[key] = int(value)

    if args.file_path is not None:
        file_path = Path(resolve_path(args.file_path))
        request["file"] = file_path.read_bytes()
        request["path"] = request.get("path", str(file_path))

    return encode_value(request)


def resolve_address(args: argparse.Namespace) -> tuple[str, int]:
    if args.addr is not None:
        host, sep, port_text = args.addr.rpartition(":")
        if not sep:
            raise SystemExit(f"invalid --addr: {args.addr!r}")
        return host or "127.0.0.1", int(port_text)

    port_file = Path(args.port_file)
    try:
        port = int(port_file.read_text().strip())
    except FileNotFoundError as exc:
        raise SystemExit(f"missing port file: {port_file}") from exc
    except ValueError as exc:
        raise SystemExit(f"invalid port file contents: {port_file}") from exc
    return "127.0.0.1", port


def read_response(sock: socket.socket) -> Any:
    data = bytearray()
    while True:
        try:
            chunk = sock.recv(65536)
        except socket.timeout as exc:
            raise SystemExit("timed out waiting for nREPL response") from exc

        if not chunk:
            break

        data.extend(chunk)
        try:
            value, used = decode_value(bytes(data))
        except BencodeNeedMoreData:
            continue

        if used != len(data):
            raise SystemExit("unexpected trailing data in nREPL response")
        return value

    if not data:
        raise SystemExit("empty nREPL response")

    try:
        value, used = decode_value(bytes(data))
    except BencodeNeedMoreData as exc:
        raise SystemExit("incomplete nREPL response") from exc

    if used != len(data):
        raise SystemExit("unexpected trailing data in nREPL response")
    return value


def response_failed(response: Any) -> bool:
    if not isinstance(response, dict):
        return False
    status = response.get(b"status")
    if not isinstance(status, list):
        return False
    return any(item == b"error" for item in status)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Talk to Ghostty's live embedded hot nREPL.",
    )
    parser.add_argument("--addr", help="host:port override; otherwise uses --port-file")
    parser.add_argument(
        "--port-file",
        default=str(DEFAULT_PORT_FILE),
        help=f"port file path (default: {DEFAULT_PORT_FILE})",
    )
    parser.add_argument("--op", help="nREPL operation, e.g. describe, eval, load-file, in-file")
    parser.add_argument("--session", default="root", help="session id (default: root)")
    parser.add_argument("--scope", help="request scope, e.g. global or session")
    parser.add_argument("--path", help="source path for in-file/load-file style requests")
    parser.add_argument("--file-path", help="file whose contents should be sent as the request file payload")
    parser.add_argument("--code", help="eval code; pass --code - to read from stdin")
    parser.add_argument("--generation", type=int, help="generation id for bind-generation/activate-generation")
    parser.add_argument(
        "--field",
        action="append",
        default=[],
        help="extra string field in KEY=VALUE form; repeat as needed",
    )
    parser.add_argument(
        "--int-field",
        action="append",
        default=[],
        help="extra integer field in KEY=VALUE form; repeat as needed",
    )
    parser.add_argument(
        "--timeout",
        type=float,
        default=5.0,
        help="socket timeout in seconds (default: 5.0)",
    )
    return parser


def main(argv: list[str]) -> int:
    args = build_parser().parse_args(argv[1:])
    request = build_request(args)
    host, port = resolve_address(args)

    with socket.create_connection((host, port), timeout=args.timeout) as sock:
        sock.settimeout(args.timeout)
        sock.sendall(request)
        response = read_response(sock)

    print(json.dumps(to_jsonable(response), indent=2, ensure_ascii=False))
    return 1 if response_failed(response) else 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
