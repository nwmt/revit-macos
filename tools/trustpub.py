#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Trust the publishers of signed add-ins, as Revit's "Always Load" button does.

  trustpub.py <out.reg> <file.dll>...   .reg (UTF-16, for `wine regedit /s`) with the signer certificate of each file
                                        in HKCU\\...\\SystemCertificates\\TrustedPublisher; prints who was added
Revit asks "This signed add-in has been found. What do you want to do?" for add-ins outside its own folders. "Always
Load" puts the signer's certificate into the user's TrustedPublisher store; under Wine that write doesn't happen, so
Revit asks on every start. The value is Wine's serialized certificate: property 3 (SHA-1 hash) + property 32 (the
certificate), each as {id, 1, length} + data; the key name is the SHA-1 thumbprint.
Run with python3 -I (the add-in files are untrusted data: we only read their signature).
"""
import hashlib, struct, sys


def tlv(d, i):
    """DER element at i -> (tag, start of content, end of element)."""
    tag, n = d[i], d[i + 1]
    i += 2
    if n & 0x80:
        k = n & 0x7F
        n = int.from_bytes(d[i:i + k], "big")
        i += k
    return tag, i, i + n


def children(d, start, end):
    out, i = [], start
    while i < end:
        t, s, e = tlv(d, i)
        out.append((t, s, e, i))
        i = e
    return out


def signer_cert(pe):
    """The Authenticode signer's certificate (DER) from a PE file, or None if unsigned."""
    off = struct.unpack_from("<I", pe, 0x3C)[0]
    dirs = off + 24 + (112 if struct.unpack_from("<H", pe, off + 24)[0] == 0x20B else 96)
    sec, size = struct.unpack_from("<II", pe, dirs + 8 * 4)  # IMAGE_DIRECTORY_ENTRY_SECURITY: a file offset
    if not size:
        return None
    length = struct.unpack_from("<I", pe, sec)[0]
    p7 = pe[sec + 8:sec + length]                              # WIN_CERTIFICATE header is 8 bytes
    _, s, e = tlv(p7, 0)                                       # ContentInfo
    _, oid_end, _ = tlv(p7, s)
    _, s0, e0 = tlv(p7, tlv(p7, s)[2])                         # [0] content
    _, ss, se = tlv(p7, s0)                                    # SignedData
    parts = children(p7, ss, se)
    certs = [p7[i:e] for t, _, e, i in children(p7, *[(s, e) for t, s, e, _ in parts if t == 0xA0][0])]
    signer_infos = [(s, e) for t, s, e, _ in parts if t == 0x31][-1]
    si = children(p7, *signer_infos)[0]                        # first SignerInfo
    sid = children(p7, si[1], si[2])[1]                        # version, sid (IssuerAndSerialNumber)
    issuer, serial = [p7[i:e] for _, _, e, i in children(p7, sid[1], sid[2])]
    for c in certs:
        _, s, e = tlv(c, 0)
        _, ts, te = tlv(c, s)                                  # tbsCertificate
        f = children(c, ts, te)
        if f[0][0] == 0xA0:                                    # explicit version
            f = f[1:]
        if c[f[0][3]:f[0][2]] == serial and c[f[2][3]:f[2][2]] == issuer:
            return c
    return None


def common_name(cert):
    i = cert.find(b"\x06\x03\x55\x04\x03")                     # OID 2.5.4.3, the last one is the subject's
    j = cert.rfind(b"\x06\x03\x55\x04\x03")
    _, s, e = tlv(cert, (j if j >= 0 else i) + 5)
    return cert[s:e].decode("utf-8", "replace")


def main():
    out, files = sys.argv[1], sys.argv[2:]
    lines = ["Windows Registry Editor Version 5.00", ""]
    for f in files:
        cert = signer_cert(open(f, "rb").read())
        if cert is None:
            print(f"{f}: not signed, skipped")
            continue
        sha1 = hashlib.sha1(cert).digest()
        blob = struct.pack("<III", 3, 1, len(sha1)) + sha1 + struct.pack("<III", 32, 1, len(cert)) + cert
        lines += [f"[HKEY_CURRENT_USER\\Software\\Microsoft\\SystemCertificates\\TrustedPublisher\\Certificates\\{sha1.hex().upper()}]",
                  '"Blob"=hex:' + ",".join(f"{b:02x}" for b in blob), ""]
        print(f"{f}: {common_name(cert)} ({sha1.hex().upper()})")
    with open(out, "w", encoding="utf-16") as fh:
        fh.write("\r\n".join(lines) + "\r\n")


if __name__ == "__main__":
    main()
