"""A minimal PostgreSQL client: verified TLS, SCRAM-SHA-256, simple queries.

Standard library only, so the restore validation Lambdas carry no
third-party code. It covers what RDS PostgreSQL 16 asks for
(rds.force_ssl=1, scram-sha-256 passwords) and nothing more: any other
authentication method is refused rather than attempted.
"""

import base64
import hashlib
import hmac
import os
import socket
import ssl
import struct

SSL_REQUEST = 80877103
PROTOCOL_3 = 196608


class Error(Exception):
    """A connection, authentication or query failure."""


def scram_proof(password, salt, iterations, auth_message):
    """Return (client proof, expected server signature) for SCRAM-SHA-256."""
    salted = hashlib.pbkdf2_hmac("sha256", password.encode(), salt, iterations)
    client_key = hmac.new(salted, b"Client Key", hashlib.sha256).digest()
    stored_key = hashlib.sha256(client_key).digest()
    signature = hmac.new(stored_key, auth_message, hashlib.sha256).digest()
    proof = bytes(a ^ b for a, b in zip(client_key, signature))
    server_key = hmac.new(salted, b"Server Key", hashlib.sha256).digest()
    return proof, hmac.new(server_key, auth_message, hashlib.sha256).digest()


def _attributes(message):
    return dict(part.split("=", 1) for part in message.split(","))


class Connection:
    """One connection to database dbname as user, over TLS verified
    against cafile with host as the expected name."""

    def __init__(self, host, port, user, password, dbname, cafile, timeout=10):
        raw = socket.create_connection((host, port), timeout=timeout)
        try:
            raw.sendall(struct.pack("!ii", 8, SSL_REQUEST))
            if raw.recv(1) != b"S":
                raise Error("server refused TLS")
            context = ssl.create_default_context(cafile=cafile)
            self._sock = context.wrap_socket(raw, server_hostname=host)
        except BaseException:
            raw.close()
            raise
        try:
            self._startup(user, password, dbname)
        except BaseException:
            self._sock.close()
            raise

    def _read_exact(self, n):
        data = b""
        while len(data) < n:
            chunk = self._sock.recv(n - len(data))
            if not chunk:
                raise Error("server closed the connection")
            data += chunk
        return data

    def _receive(self):
        kind, length = struct.unpack("!ci", self._read_exact(5))
        return kind, self._read_exact(length - 4)

    def _send(self, kind, body):
        self._sock.sendall(kind + struct.pack("!i", len(body) + 4) + body)

    @staticmethod
    def _error(body):
        fields = {}
        for field in body.split(b"\0"):
            if field:
                fields[field[:1]] = field[1:].decode(errors="replace")
        return Error("%s %s: %s" % (fields.get(b"S", "ERROR"), fields.get(b"C", "?"), fields.get(b"M", "")))

    def _startup(self, user, password, dbname):
        params = b"".join(k.encode() + b"\0" + v.encode() + b"\0" for k, v in
                          (("user", user), ("database", dbname), ("client_encoding", "UTF8")))
        body = struct.pack("!i", PROTOCOL_3) + params + b"\0"
        self._sock.sendall(struct.pack("!i", len(body) + 4) + body)
        nonce = base64.b64encode(os.urandom(18)).decode()
        client_first_bare = "n=,r=" + nonce
        expected_signature = None
        while True:
            kind, body = self._receive()
            if kind == b"E":
                raise self._error(body)
            if kind == b"Z":
                if expected_signature is None:
                    raise Error("server accepted the connection without SCRAM authentication")
                return
            if kind != b"R":
                continue  # ParameterStatus, BackendKeyData, notices
            code = struct.unpack("!i", body[:4])[0]
            if code == 10:  # SASL: the mechanisms offered
                if "SCRAM-SHA-256" not in body[4:].decode().split("\0"):
                    raise Error("server doesn't offer SCRAM-SHA-256")
                first = ("n,," + client_first_bare).encode()
                self._send(b"p", b"SCRAM-SHA-256\0" + struct.pack("!i", len(first)) + first)
            elif code == 11:  # SASLContinue: server-first-message
                server_first = body[4:].decode()
                attrs = _attributes(server_first)
                if not attrs["r"].startswith(nonce):
                    raise Error("server nonce doesn't extend the client's")
                final_without_proof = "c=biws,r=" + attrs["r"]
                auth_message = ",".join((client_first_bare, server_first, final_without_proof)).encode()
                proof, expected_signature = scram_proof(password, base64.b64decode(attrs["s"]), int(attrs["i"]), auth_message)
                self._send(b"p", (final_without_proof + ",p=" + base64.b64encode(proof).decode()).encode())
            elif code == 12:  # SASLFinal: the server proves it knows the password too
                signature = base64.b64decode(_attributes(body[4:].decode())["v"])
                if expected_signature is None or not hmac.compare_digest(signature, expected_signature):
                    raise Error("server signature doesn't match")
            elif code != 0:
                raise Error("unsupported authentication request %d" % code)

    def query(self, sql):
        """Run sql (one statement) and return its rows as lists of text."""
        self._send(b"Q", sql.encode() + b"\0")
        rows, failure = [], None
        while True:
            kind, body = self._receive()
            if kind == b"D":
                count, offset, row = struct.unpack("!h", body[:2])[0], 2, []
                for _ in range(count):
                    size = struct.unpack("!i", body[offset:offset + 4])[0]
                    offset += 4
                    if size < 0:
                        row.append(None)
                    else:
                        row.append(body[offset:offset + size].decode())
                        offset += size
                rows.append(row)
            elif kind == b"E":
                failure = self._error(body)
            elif kind == b"Z":
                if failure:
                    raise failure
                return rows

    def close(self):
        try:
            self._send(b"X", b"")
        except OSError:
            pass
        self._sock.close()
