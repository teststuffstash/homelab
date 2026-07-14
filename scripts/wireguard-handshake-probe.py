#!/usr/bin/env python3
"""One-shot WireGuard handshake-initiation test (Noise_IKpsk2, no PSK).

Sends a valid type-1 initiation to the server using the client's static key and
waits for the type-2 response (92 bytes). A response proves: UDP path + firewall
rule + server key + peer registration all work. No transport data is exchanged.
"""
import hashlib, hmac, os, socket, struct, sys, time

from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey, X25519PublicKey
from cryptography.hazmat.primitives.ciphers.aead import ChaCha20Poly1305
from cryptography.hazmat.primitives import serialization

import base64

HOST, PORT = sys.argv[1], int(sys.argv[2])
CLIENT_PRIV = base64.b64decode(sys.argv[3])
SERVER_PUB = base64.b64decode(sys.argv[4])

CONSTRUCTION = b"Noise_IKpsk2_25519_ChaChaPoly_BLAKE2s"
IDENTIFIER = b"WireGuard v1 zx2c4 Jason@zx2c4.com"
LABEL_MAC1 = b"mac1----"

def HASH(d): return hashlib.blake2s(d).digest()
def HMAC(k, d): return hmac.new(k, d, hashlib.blake2s).digest()

def KDF(n, key, input_):
    t0 = HMAC(key, input_)
    out, prev = [], b""
    for i in range(1, n + 1):
        prev = HMAC(t0, prev + bytes([i]))
        out.append(prev)
    return out

def DH(priv, pub):
    return X25519PrivateKey.from_private_bytes(priv).exchange(X25519PublicKey.from_public_bytes(pub))

def AEAD(key, counter, plain, auth):
    return ChaCha20Poly1305(key).encrypt(b"\x00" * 4 + struct.pack("<Q", counter), plain, auth)

client_priv = CLIENT_PRIV
client_pub = X25519PrivateKey.from_private_bytes(client_priv).public_key().public_bytes(
    serialization.Encoding.Raw, serialization.PublicFormat.Raw)

ck = HASH(CONSTRUCTION)
h = HASH(ck + IDENTIFIER)
h = HASH(h + SERVER_PUB)

eph_priv_obj = X25519PrivateKey.generate()
eph_priv = eph_priv_obj.private_bytes(
    serialization.Encoding.Raw, serialization.PrivateFormat.Raw, serialization.NoEncryption())
eph_pub = eph_priv_obj.public_key().public_bytes(
    serialization.Encoding.Raw, serialization.PublicFormat.Raw)

(ck,) = KDF(1, ck, eph_pub)
h = HASH(h + eph_pub)
ck, k = KDF(2, ck, DH(eph_priv, SERVER_PUB))
enc_static = AEAD(k, 0, client_pub, h)
h = HASH(h + enc_static)
ck, k = KDF(2, ck, DH(client_priv, SERVER_PUB))
# TAI64N timestamp
now = time.time()
tai64n = struct.pack(">QI", 0x400000000000000A + int(now), int((now % 1) * 1e9))
enc_ts = AEAD(k, 0, tai64n, h)
h = HASH(h + enc_ts)

sender_index = struct.unpack("<I", os.urandom(4))[0]
msg = struct.pack("<I", 1) + struct.pack("<I", sender_index) + eph_pub + enc_static + enc_ts
mac1_key = HASH(LABEL_MAC1 + SERVER_PUB)
mac1 = hashlib.blake2s(msg, digest_size=16, key=mac1_key).digest()
msg += mac1 + b"\x00" * 16  # mac2 = zeros (no cookie in play)
assert len(msg) == 148, len(msg)

s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.settimeout(5)
s.sendto(msg, (HOST, PORT))
try:
    data, addr = s.recvfrom(2048)
except socket.timeout:
    print("TIMEOUT: no handshake response")
    sys.exit(1)
mtype = struct.unpack("<I", data[:4])[0]
print(f"response: {len(data)} bytes from {addr}, message type {mtype}")
if mtype == 2 and len(data) == 92:
    receiver = struct.unpack("<I", data[8:12])[0]
    print(f"HANDSHAKE_OK (responder acknowledged our sender index: {receiver == sender_index})")
    sys.exit(0)
print("UNEXPECTED response")
sys.exit(1)
