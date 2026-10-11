#!/usr/bin/env python3
"""Prepare this client's App Store profile using the existing CI signing identity.

Credentials stay in the CI environment and a protected ASC_KEY_PATH file. This
helper never creates certificates, changes another app, or uploads an app.
"""

from __future__ import annotations

import argparse
import base64
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import stat
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

API_ORIGIN = "https://api.appstoreconnect.apple.com"
CLIENT_BUNDLE_ID = "com.ayato.y3posclient"
DEFAULT_PROFILE_NAME = "Y3POSClient-AppStore-GitHubActions"


class SigningError(RuntimeError):
    pass


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def decode_base64(value: str) -> bytes:
    try:
        return base64.b64decode("".join(value.split()), validate=True)
    except (ValueError, TypeError) as exc:
        raise SigningError("Apple returned an invalid Base64 signing asset.") from exc


def run_openssl(arguments: list[str], data: bytes | None = None) -> bytes:
    try:
        result = subprocess.run(
            ["openssl", *arguments], input=data, capture_output=True, check=False
        )
    except OSError as exc:
        raise SigningError("OpenSSL is required on the signing runner.") from exc
    if result.returncode:
        # OpenSSL error output can contain paths or supplied inputs; keep it private.
        raise SigningError("OpenSSL could not validate or process the signing asset.")
    return result.stdout


def der_signature_to_raw(signature: bytes) -> bytes:
    """Convert the ASN.1 ECDSA signature to JWT's fixed-width R || S format."""
    def element(offset: int, tag: int) -> tuple[bytes, int]:
        if offset + 2 > len(signature) or signature[offset] != tag:
            raise SigningError("OpenSSL returned an invalid ES256 signature.")
        length = signature[offset + 1]
        offset += 2
        if length & 0x80:
            count = length & 0x7F
            if not count or count > 2 or offset + count > len(signature):
                raise SigningError("OpenSSL returned an invalid ES256 length.")
            length = int.from_bytes(signature[offset:offset + count], "big")
            offset += count
        end = offset + length
        if end > len(signature):
            raise SigningError("OpenSSL returned a truncated ES256 signature.")
        return signature[offset:end], end

    sequence, end = element(0, 0x30)
    if end != len(signature):
        raise SigningError("OpenSSL returned trailing ES256 signature data.")
    start = len(signature) - len(sequence)
    r, offset = element(start, 0x02)
    s, offset = element(offset, 0x02)
    if offset != len(signature):
        raise SigningError("OpenSSL returned an invalid ES256 signature pair.")
    integers = []
    for value in (r, s):
        if not value or value[0] & 0x80 or len(value) > 33:
            raise SigningError("OpenSSL returned an invalid ES256 integer.")
        number = int.from_bytes(value, "big")
        if not 0 < number < 2 ** 256:
            raise SigningError("OpenSSL returned an invalid ES256 integer size.")
        integers.append(number.to_bytes(32, "big"))
    return b"".join(integers)


def make_jwt(key_id: str, issuer_id: str, key_path: Path) -> str:
    if not re.fullmatch(r"[A-Z0-9]{10}", key_id):
        raise SigningError("ASC_KEY_ID must be an App Store Connect key identifier.")
    try:
        issuer_id = str(uuid.UUID(issuer_id))
    except ValueError as exc:
        raise SigningError("ASC_ISSUER_ID must be the API key issuer UUID.") from exc
    try:
        key_stat = key_path.stat()
    except OSError as exc:
        raise SigningError("ASC_KEY_PATH must identify the CI API private key file.") from exc
    if not stat.S_ISREG(key_stat.st_mode) or key_stat.st_size > 32768:
        raise SigningError("ASC_KEY_PATH does not identify a valid key file.")
    if key_stat.st_mode & 0o077:
        raise SigningError("The App Store Connect key file must have mode 600.")
    public_der = run_openssl(["pkey", "-in", str(key_path), "-pubout", "-outform", "DER"])
    if bytes.fromhex("06082a8648ce3d030107") not in public_der:
        raise SigningError("The App Store Connect API key must use the P-256 curve.")
    now = int(time.time())
    header = {"alg": "ES256", "kid": key_id, "typ": "JWT"}
    claims = {"iss": issuer_id, "iat": now, "exp": now + 600, "aud": "appstoreconnect-v1"}
    unsigned = ".".join(b64url(json.dumps(v, separators=(",", ":")).encode()) for v in (header, claims))
    signature = run_openssl(["dgst", "-sha256", "-sign", str(key_path)], unsigned.encode())
    return unsigned + "." + b64url(der_signature_to_raw(signature))


class NoRedirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class AppleAPI:
    def __init__(self, token: str):
        self.token = token
        self.opener = urllib.request.build_opener(NoRedirects())

    def request(self, method: str, path: str, body: dict | None = None) -> dict:
        url = path if path.startswith("https://") else API_ORIGIN + path
        parsed = urllib.parse.urlsplit(url)
        if parsed.scheme != "https" or parsed.netloc != "api.appstoreconnect.apple.com" or not parsed.path.startswith("/v1/"):
            raise SigningError("Refusing to send signing credentials outside Apple's API.")
        data = json.dumps(body).encode() if body is not None else None
        headers = {"Authorization": "Bearer " + self.token, "Accept": "application/json"}
        if data is not None:
            headers["Content-Type"] = "application/json"
        for attempt in range(3):
            try:
                req = urllib.request.Request(url, data=data, headers=headers, method=method)
                with self.opener.open(req, timeout=45) as response:
                    return json.load(response)
            except urllib.error.HTTPError as exc:
                if method == "GET" and (exc.code == 429 or exc.code >= 500) and attempt < 2:
                    time.sleep(1 + attempt)
                    continue
                try:
                    errors = json.loads(exc.read(65536)).get("errors", [])
                    codes = [e.get("code", "") for e in errors]
                    codes = [c for c in codes if re.fullmatch(r"[A-Za-z0-9_.-]{1,100}", c)]
                except (ValueError, AttributeError, TypeError):
                    codes = []
                if exc.code == 401:
                    reason = "Check ASC_KEY_ID, ASC_ISSUER_ID and the matching ASC_PRIVATE_KEY."
                elif exc.code == 403:
                    reason = "The existing API key needs Certificates, Identifiers & Profiles access and permission to register this bundle/profile."
                else:
                    reason = "Apple error codes: " + (", ".join(codes) or "unavailable")
                raise SigningError(f"Apple API {method} {parsed.path} failed (HTTP {exc.code}). {reason}") from None
            except (urllib.error.URLError, TimeoutError, OSError) as exc:
                if method == "GET" and attempt < 2:
                    time.sleep(1 + attempt)
                    continue
                raise SigningError(f"Apple API {method} {parsed.path} could not complete. Rerun to check for any resource created before the connection failed.") from None
            except (ValueError, TypeError) as exc:
                raise SigningError("Apple returned an invalid API response.") from exc
        raise SigningError("Apple API request could not complete.")

    def collection(self, path: str, filters: dict | None = None) -> list[dict]:
        params = {"limit": "200", **(filters or {})}
        next_url = path + "?" + urllib.parse.urlencode(params)
        result, seen = [], set()
        while next_url:
            if next_url in seen or len(seen) >= 100:
                raise SigningError("Apple returned invalid pagination for signing assets.")
            seen.add(next_url)
            response = self.request("GET", next_url)
            if not isinstance(response.get("data"), list):
                raise SigningError("Apple returned an invalid signing asset list.")
            result.extend(response["data"])
            next_url = response.get("links", {}).get("next")
        return result


def is_future(value: str | dt.datetime | None) -> bool:
    if isinstance(value, str):
        try:
            value = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
        except ValueError:
            return False
    if not isinstance(value, dt.datetime):
        return False
    if value.tzinfo is None:
        value = value.replace(tzinfo=dt.timezone.utc)
    return value > dt.datetime.now(dt.timezone.utc)


def validate_profile(resource: dict, certificate_der: bytes, bundle_id: str, team_id: str) -> tuple[bytes, dict]:
    attrs = resource.get("attributes", {})
    if attrs.get("profileType") != "IOS_APP_STORE" or attrs.get("profileState") != "ACTIVE":
        raise SigningError("The profile is not an active iOS App Store profile.")
    raw = decode_base64(attrs.get("profileContent", ""))
    if not raw or len(raw) > 10 * 1024 * 1024:
        raise SigningError("The provisioning profile content is missing or invalid.")
    try:
        decoded = plistlib.loads(run_openssl(["cms", "-verify", "-inform", "DER", "-noverify"], raw))
    except (ValueError, plistlib.InvalidFileException) as exc:
        raise SigningError("The provisioning profile could not be decoded.") from exc
    entitlements = decoded.get("Entitlements", {})
    application_id = entitlements.get("application-identifier", "")
    if "." not in application_id or application_id.split(".", 1)[1] != bundle_id:
        raise SigningError("The profile belongs to a different app; refusing to use it.")
    if team_id not in decoded.get("TeamIdentifier", []) or entitlements.get("com.apple.developer.team-identifier") != team_id:
        raise SigningError("The profile belongs to a different Apple team.")
    if certificate_der not in decoded.get("DeveloperCertificates", []):
        raise SigningError("The profile does not include the imported signing certificate.")
    if entitlements.get("get-task-allow", False) or "ProvisionedDevices" in decoded or decoded.get("ProvisionsAllDevices", False):
        raise SigningError("The profile's device/debug permissions do not match App Store distribution.")
    if not is_future(decoded.get("ExpirationDate")) or not is_future(attrs.get("expirationDate")):
        raise SigningError("The provisioning profile has expired.")
    profile_uuid = decoded.get("UUID", "")
    try:
        uuid.UUID(profile_uuid)
    except (ValueError, TypeError, AttributeError) as exc:
        raise SigningError("The provisioning profile UUID is invalid.") from exc
    if attrs.get("uuid", "").lower() != profile_uuid.lower():
        raise SigningError("The profile UUID does not match Apple's API metadata.")
    return raw, {
        "profile_name": decoded.get("Name", attrs.get("name")),
        "profile_uuid": profile_uuid,
        "bundle_identifier": bundle_id,
        "team_identifier": team_id,
        "certificate_sha1": hashlib.sha1(certificate_der).hexdigest().upper(),
        "profile_type": "IOS_APP_STORE",
        "profile_resource_id": resource["id"],
        "expiration_date": attrs["expirationDate"],
    }


def prepare_profile(api: AppleAPI, certificate_der: bytes, bundle_id: str, team_id: str, profile_name: str) -> tuple[bytes, dict]:
    if bundle_id != CLIENT_BUNDLE_ID:
        raise SigningError("This helper may only provision com.ayato.y3posclient.")
    if not re.fullmatch(r"[A-Z0-9]{10}", team_id):
        raise SigningError("The existing APPLE_TEAM_ID must be a valid Apple team identifier.")
    subject = run_openssl(["x509", "-inform", "DER", "-noout", "-subject", "-nameopt", "RFC2253"], certificate_der).decode("utf-8")
    subject = re.sub(r"^subject\s*=\s*", "", subject.strip())
    teams = re.findall(r"(?:^|,)OU=([A-Z0-9]{10})(?=,|$)", subject)
    if team_id not in teams:
        raise SigningError("The imported certificate belongs to a different Apple team. No bundle or profile was created.")
    fingerprint = hashlib.sha1(certificate_der).digest()
    certificate = None
    for resource in api.collection("/v1/certificates"):
        attrs = resource.get("attributes", {})
        content = attrs.get("certificateContent")
        if not content or hashlib.sha1(decode_base64(content)).digest() != fingerprint:
            continue
        if attrs.get("certificateType") not in ("IOS_DISTRIBUTION", "DISTRIBUTION") or not is_future(attrs.get("expirationDate")):
            raise SigningError("The imported certificate is not a valid iOS distribution certificate.")
        certificate = resource
        break
    if certificate is None:
        raise SigningError("The imported P12 certificate is not present in the existing API key's Apple team. No new certificate was created.")

    bundles = api.collection("/v1/bundleIds", {"filter[identifier]": bundle_id, "filter[platform]": "IOS"})
    bundles = [r for r in bundles if r.get("attributes", {}).get("identifier") == bundle_id and r.get("attributes", {}).get("platform") == "IOS"]
    if len(bundles) > 1:
        raise SigningError("Apple returned multiple registrations for this exact bundle.")
    if bundles:
        bundle = bundles[0]
    else:
        bundle = api.request("POST", "/v1/bundleIds", {"data": {"type": "bundleIds", "attributes": {"name": "Y3 POS Client", "identifier": bundle_id, "platform": "IOS"}}})["data"]
    if bundle.get("attributes", {}).get("identifier") != bundle_id or bundle.get("attributes", {}).get("platform") != "IOS":
        raise SigningError("Apple returned a different bundle registration.")

    # Apple's profiles list does not support filter[bundleId]. This relationship
    # endpoint scopes the lookup to the registered client without reading other
    # applications' profile content. Type/state are validated below.
    profiles = api.collection("/v1/bundleIds/" + bundle["id"] + "/profiles", {
        "fields[profiles]": "name,uuid,profileType,profileState,profileContent,expirationDate"
    })
    profiles.sort(key=lambda p: (p.get("attributes", {}).get("name") == profile_name, p.get("attributes", {}).get("expirationDate", "")), reverse=True)
    for profile in profiles:
        if not profile.get("attributes", {}).get("profileContent"):
            # Missing content is not proof that the existing profile is invalid.
            # A read failure must stop setup rather than create a duplicate.
            profile = api.request("GET", "/v1/profiles/" + profile["id"])["data"]
        try:
            raw, metadata = validate_profile(profile, certificate_der, bundle_id, team_id)
        except SigningError:
            continue
        metadata.update(bundle_id_resource_id=bundle["id"], reused=True)
        return raw, metadata

    created = api.request("POST", "/v1/profiles", {"data": {
        "type": "profiles",
        "attributes": {"name": profile_name, "profileType": "IOS_APP_STORE"},
        "relationships": {
            "bundleId": {"data": {"type": "bundleIds", "id": bundle["id"]}},
            "certificates": {"data": [{"type": "certificates", "id": certificate["id"]}]},
        },
    }})["data"]
    if not created.get("attributes", {}).get("profileContent"):
        created = api.request("GET", "/v1/profiles/" + created["id"])["data"]
    raw, metadata = validate_profile(created, certificate_der, bundle_id, team_id)
    metadata.update(bundle_id_resource_id=bundle["id"], reused=False)
    return raw, metadata


def write_private(path: Path, content: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    # Atomic replacement avoids leaving a partially written profile after interruption.
    descriptor, temp_name = tempfile.mkstemp(prefix=path.name + ".", suffix=".tmp", dir=path.parent)
    temp = Path(temp_name)
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(content)
        os.replace(temp, path)
    finally:
        if temp.exists():
            temp.unlink()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--certificate-der", type=Path, required=True)
    parser.add_argument("--output-profile", type=Path, required=True)
    parser.add_argument("--bundle-id", required=True)
    parser.add_argument("--team-id", required=True)
    parser.add_argument("--output-metadata", type=Path, required=True)
    parser.add_argument("--profile-name", default=DEFAULT_PROFILE_NAME)
    args = parser.parse_args()
    try:
        if args.bundle_id != CLIENT_BUNDLE_ID:
            raise SigningError("This helper may only provision com.ayato.y3posclient.")
        values = {name: os.environ.get(name, "") for name in ("ASC_KEY_ID", "ASC_ISSUER_ID", "ASC_KEY_PATH")}
        if any(not value for value in values.values()):
            raise SigningError("CI must provide ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_PATH.")
        certificate_der = args.certificate_der.read_bytes()
        run_openssl(["x509", "-inform", "DER", "-noout", "-checkend", "0"], certificate_der)
        token = make_jwt(values["ASC_KEY_ID"], values["ASC_ISSUER_ID"], Path(values["ASC_KEY_PATH"]))
        raw, metadata = prepare_profile(AppleAPI(token), certificate_der, args.bundle_id, args.team_id, args.profile_name)
        write_private(args.output_profile, raw)
        write_private(args.output_metadata, (json.dumps(metadata, indent=2) + "\n").encode())
        print("Y3 POS Client App Store profile " + ("reused" if metadata["reused"] else "created") + ".")
        return 0
    except (SigningError, OSError, KeyError, TypeError) as exc:
        message = str(exc) if isinstance(exc, SigningError) else "The signing input or Apple response is incomplete."
        print("Signing setup failed: " + message, file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
