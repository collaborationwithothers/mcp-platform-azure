#!/usr/bin/env python3
"""Serve a disposable OpenID Connect issuer for local container tests."""

import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from functools import partial
from http.server import BaseHTTPRequestHandler, HTTPServer


TOKEN_LIFETIME_SECONDS = 300
ROLES = ["Orders.Invoke.All", "ServiceInfo.Read"]


def base64url(value: bytes) -> str:
    return base64.urlsafe_b64encode(value).rstrip(b"=").decode("ascii")


def openssl(command: list[str], *, input_bytes: bytes | None = None) -> bytes:
    executable = shutil.which("openssl")
    if executable is None:
        raise RuntimeError("openssl is required but was not found on PATH")

    result = subprocess.run(
        [executable, *command],
        input=input_bytes,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if result.returncode != 0:
        error = result.stderr.decode("utf-8", errors="replace").strip()
        raise RuntimeError(f"openssl {' '.join(command)} failed: {error}")
    return result.stdout


def generate_key(key_path: Path) -> tuple[str, str]:
    openssl(
        [
            "genpkey",
            "-algorithm",
            "RSA",
            "-pkeyopt",
            "rsa_keygen_bits:2048",
            "-pkeyopt",
            "rsa_keygen_pubexp:65537",
            "-out",
            str(key_path),
        ]
    )
    modulus_output = openssl(
        ["rsa", "-in", str(key_path), "-noout", "-modulus"]
    ).decode("ascii").strip()
    prefix = "Modulus="
    if not modulus_output.startswith(prefix):
        raise RuntimeError("openssl returned an unexpected RSA modulus format")

    modulus = int(modulus_output[len(prefix) :], 16)
    modulus_bytes = modulus.to_bytes((modulus.bit_length() + 7) // 8, "big")
    public_der = openssl(
        ["pkey", "-in", str(key_path), "-pubout", "-outform", "DER"]
    )
    key_id = base64url(hashlib.sha256(public_der).digest())
    return key_id, base64url(modulus_bytes)


def mint_token(key_path: Path, key_id: str, issuer: str, audience: str) -> str:
    now = int(time.time())
    header = {"alg": "RS256", "kid": key_id, "typ": "JWT"}
    payload = {
        "aud": audience,
        "azp": "oidc-ci-client",
        "exp": now + TOKEN_LIFETIME_SECONDS,
        "iat": now,
        "iss": issuer,
        "nbf": now - 5,
        "oid": "00000000-0000-4000-8000-000000000148",
        "roles": ROLES,
        "sub": "oidc-ci-client",
    }

    encoded_header = base64url(
        json.dumps(header, separators=(",", ":"), sort_keys=True).encode("utf-8")
    )
    encoded_payload = base64url(
        json.dumps(payload, separators=(",", ":"), sort_keys=True).encode("utf-8")
    )
    signing_input = f"{encoded_header}.{encoded_payload}".encode("ascii")
    signature = openssl(
        ["dgst", "-sha256", "-sign", str(key_path)],
        input_bytes=signing_input,
    )
    return f"{signing_input.decode('ascii')}.{base64url(signature)}"


def write_token(path: Path, token: str) -> None:
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            descriptor = -1
            stream.write(token)
    finally:
        if descriptor >= 0:
            os.close(descriptor)


class OidcRequestHandler(BaseHTTPRequestHandler):
    def __init__(self, *args: object, documents: dict[str, bytes], **kwargs: object):
        self.documents = documents
        super().__init__(*args, **kwargs)

    def do_GET(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
        body = self.documents.get(self.path)
        status = 200
        if body is None:
            status = 404
            body = b'{"error":"not_found"}'

        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, _format: str, *args: object) -> None:
        pass


def required_port(value: str) -> int:
    port = int(value)
    if not 1 <= port <= 65535:
        raise argparse.ArgumentTypeError("port must be between 1 and 65535")
    return port


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--issuer", required=True)
    parser.add_argument("--audience", required=True)
    parser.add_argument("--token-file", required=True, type=Path)
    parser.add_argument("--host", required=True)
    parser.add_argument("--port", required=True, type=required_port)
    return parser.parse_args()


def json_bytes(value: object) -> bytes:
    return json.dumps(value, separators=(",", ":"), sort_keys=True).encode("utf-8")


def main() -> None:
    args = parse_args()
    with tempfile.TemporaryDirectory(prefix="mcp-oidc-") as temporary_directory:
        key_path = Path(temporary_directory) / "private.pem"
        key_id, modulus = generate_key(key_path)
        token = mint_token(key_path, key_id, args.issuer, args.audience)

        documents = {
            "/.well-known/openid-configuration": json_bytes(
                {
                    "issuer": args.issuer,
                    "jwks_uri": f"{args.issuer.rstrip('/')}/jwks",
                    "id_token_signing_alg_values_supported": ["RS256"],
                    "response_types_supported": [],
                    "subject_types_supported": ["public"],
                }
            ),
            "/jwks": json_bytes(
                {
                    "keys": [
                        {
                            "alg": "RS256",
                            "e": "AQAB",
                            "kid": key_id,
                            "kty": "RSA",
                            "n": modulus,
                            "use": "sig",
                        }
                    ]
                }
            ),
        }
        handler = partial(OidcRequestHandler, documents=documents)
        server = HTTPServer((args.host, args.port), handler)
        write_token(args.token_file, token)
        signal.signal(signal.SIGTERM, lambda _signum, _frame: sys.exit(0))
        print(
            f"OIDC test server listening on http://{args.host}:{args.port}",
            flush=True,
        )
        try:
            server.serve_forever()
        except KeyboardInterrupt:
            pass
        finally:
            server.server_close()


if __name__ == "__main__":
    main()
