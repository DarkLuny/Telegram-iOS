#!/usr/bin/env python3
"""Rewrite the expiry of the bundled fake provisioning profiles.

`build-system/fake-codesigning/profiles/*.mobileprovision` are real App Store
profiles whose developer certificate has been swapped for the throwaway
self-signed one in `certs/SelfSigned.p12`. They are only used so that
`rules_apple` can compute the `application-identifier` prefix and validate the
entitlements template; the IPA that comes out of this build is unsigned and is
re-signed by Sideloadly with the user's own free-identity profile, which
replaces the embedded profile entirely.

The problem is that Apple stamps every profile with an `ExpirationDate`, and
`plisttool` refuses to build once that date is in the past:

    ERROR: On target "@@//Telegram:Telegram", provisioning profile
    ExpirationDate ("2026-10-30T17:06:30") is in the past.

Upstream refreshes the checked-in copies every so often; this script does the
same thing without an App Store Connect account. It decodes the CMS envelope,
pushes `CreationDate`/`ExpirationDate` forward, and re-signs the plist with the
same self-signed certificate.

Usage:
    python3 build-system/fake-codesigning/refresh_profiles.py [--years 10]
"""

import argparse
import datetime
import glob
import io
import os
import plistlib
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
PROFILES = os.path.join(HERE, "profiles")
P12 = os.path.join(HERE, "certs", "SelfSigned.p12")
P12_PASSWORD = ""


def decode(profile_bytes):
    """Return the XML plist embedded in a .mobileprovision file.

    The file is a CMS SignedData with the plist as the encapsulated content, so
    the payload sits between the first `<?xml` and the final `</plist>`; the
    surrounding bytes are the signature and need not be parsed to read it.
    """
    start = profile_bytes.find(b"<?xml")
    end = profile_bytes.rfind(b"</plist>")
    if start < 0 or end < 0:
        raise SystemExit("not a CMS-wrapped plist")
    return profile_bytes[start:end + len(b"</plist>")]


def extract_identity(p12_path):
    """Write the certificate and key out of the p12 so openssl can sign."""
    cert = subprocess.run(
        ["openssl", "pkcs12", "-in", p12_path, "-passin", "pass:" + P12_PASSWORD,
         "-nokeys", "-clcerts", "-legacy"],
        check=True, capture_output=True).stdout
    key = subprocess.run(
        ["openssl", "pkcs12", "-in", p12_path, "-passin", "pass:" + P12_PASSWORD,
         "-nocerts", "-nodes", "-legacy"],
        check=True, capture_output=True).stdout
    return cert, key


def sign(plist_bytes, cert, key, destination):
    """Wrap the plist back in a CMS SignedData envelope, as `security cms -S` does."""
    workdir = tempfile.mkdtemp()
    cert_path = os.path.join(workdir, "cert.pem")
    key_path = os.path.join(workdir, "key.pem")
    plist_path = os.path.join(workdir, "profile.plist")
    with open(cert_path, "wb") as handle:
        handle.write(cert)
    with open(key_path, "wb") as handle:
        handle.write(key)
    with open(plist_path, "wb") as handle:
        handle.write(plist_bytes)
    subprocess.run(
        ["openssl", "cms", "-sign", "-binary", "-nodetach",
         "-in", plist_path, "-signer", cert_path, "-inkey", key_path,
         "-outform", "DER", "-out", destination],
        check=True, capture_output=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--years", type=int, default=10,
                        help="how long the rewritten profiles should last")
    arguments = parser.parse_args()

    cert, key = extract_identity(P12)
    # plistlib writes naive datetimes with a trailing "Z", which is what the
    # Apple profiles use; `utcnow()` would be the obvious way to get that value
    # but it is deprecated, so take the aware clock and drop the tzinfo.
    now = datetime.datetime.now(datetime.timezone.utc).replace(
        tzinfo=None, microsecond=0)
    expires = now + datetime.timedelta(days=365 * arguments.years)

    paths = sorted(glob.glob(os.path.join(PROFILES, "*.mobileprovision")))
    if not paths:
        raise SystemExit("no profiles found in %s" % PROFILES)

    for path in paths:
        with open(path, "rb") as handle:
            original = handle.read()
        metadata = plistlib.loads(decode(original))
        if metadata.get("ExpirationDate", datetime.datetime.min) > expires:
            print("%s: already valid until %s" % (
                os.path.basename(path), metadata["ExpirationDate"]))
            continue

        metadata["CreationDate"] = now
        metadata["ExpirationDate"] = expires
        rewritten = plistlib.dumps(metadata, fmt=plistlib.FMT_XML)
        sign(rewritten, cert, key, path)

        check = plistlib.loads(decode(open(path, "rb").read()))
        assert check["ExpirationDate"] == expires, path
        print("%s: %s -> %s (%s)" % (
            os.path.basename(path), metadata["Name"],
            expires.isoformat(), len(original)))


if __name__ == "__main__":
    sys.exit(main())