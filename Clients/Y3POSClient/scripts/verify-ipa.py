#!/usr/bin/env python3
"""Verify an exported iOS IPA without publishing signing or device secrets.

Only a successful verification writes the requested JSON file. Apple signing
commands run on macOS; ZIP, plist, and entitlement helpers remain portable.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import stat
import struct
import subprocess
import sys
import tempfile
import unicodedata
import uuid
from xml.parsers.expat import ExpatError
import zipfile


UTC = dt.timezone.utc
MAX_ENTRIES = 25000
MAX_UNCOMPRESSED_BYTES = 1024 * 1024 * 1024
MAX_FILE_BYTES = 512 * 1024 * 1024
EXPORT_METHODS = ("app-store-connect", "release-testing", "debugging", "development")


class VerificationError(Exception):
    """A deliberately sanitized, actionable failure."""


def require(condition: bool, message: str) -> None:
    if not condition:
        raise VerificationError(message)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def safe_extract(ipa: Path, destination: Path) -> None:
    """Extract only ordinary files/directories, with bounded streamed reads."""
    try:
        with zipfile.ZipFile(ipa) as archive:
            entries = archive.infolist()
            require(0 < len(entries) <= MAX_ENTRIES, "IPA ZIP has an invalid entry count.")
            names: dict[str, bool] = {}
            planned: list[tuple[zipfile.ZipInfo, tuple[str, ...], bool]] = []
            declared_total = 0
            for entry in entries:
                original = entry.orig_filename
                require(
                    original == entry.filename
                    and original
                    and not any(ord(c) < 32 or ord(c) == 127 for c in original)
                    and "\\" not in original
                    and ":" not in original
                    and not original.startswith("/"),
                    "IPA ZIP contains an unsafe entry name.",
                )
                is_directory = entry.is_dir()
                name = original[:-1] if is_directory else original
                parts = tuple(name.split("/"))
                require(all(p and p not in (".", "..") for p in parts), "IPA ZIP contains an unsafe path.")
                mode = (entry.external_attr >> 16) & 0xFFFF
                kind = stat.S_IFMT(mode)
                require(kind in (0, stat.S_IFREG, stat.S_IFDIR), "IPA ZIP contains a symlink or special file.")
                require(
                    (kind != stat.S_IFDIR or is_directory) and (kind != stat.S_IFREG or not is_directory),
                    "IPA ZIP has inconsistent file types.",
                )
                require(not (entry.flag_bits & 1), "Encrypted IPA ZIP entries are unsupported.")
                require(entry.compress_type in (zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED), "Unsupported IPA ZIP compression.")
                require(0 <= entry.file_size <= MAX_FILE_BYTES, "IPA ZIP entry exceeds the size limit.")
                require(not is_directory or entry.file_size == 0, "IPA ZIP directory contains data.")
                declared_total += entry.file_size
                require(declared_total <= MAX_UNCOMPRESSED_BYTES, "IPA ZIP exceeds the extracted size limit.")
                # macOS filesystems may compare case and Unicode-normalized names.
                canonical = unicodedata.normalize("NFD", name).casefold()
                require(canonical not in names, "IPA ZIP contains duplicate or colliding paths.")
                names[canonical] = is_directory
                planned.append((entry, parts, is_directory))

            for _, parts, _ in planned:
                for length in range(1, len(parts)):
                    ancestor = unicodedata.normalize("NFD", "/".join(parts[:length])).casefold()
                    require(ancestor not in names or names[ancestor], "IPA ZIP contains a file/directory collision.")

            total_read = 0
            for entry, parts, is_directory in planned:
                target = destination.joinpath(*parts)
                if is_directory:
                    target.mkdir(parents=True, exist_ok=True)
                    continue
                target.parent.mkdir(parents=True, exist_ok=True)
                read_count = 0
                with archive.open(entry) as source, target.open("xb") as output:
                    while True:
                        chunk = source.read(1024 * 1024)
                        if not chunk:
                            break
                        read_count += len(chunk)
                        total_read += len(chunk)
                        require(
                            read_count <= entry.file_size and total_read <= MAX_UNCOMPRESSED_BYTES,
                            "IPA ZIP data exceeds its declared size.",
                        )
                        output.write(chunk)
                require(read_count == entry.file_size, "IPA ZIP entry has an incorrect extracted size.")
                target.chmod(0o755 if (entry.external_attr >> 16) & 0o111 else 0o644)
    except (zipfile.BadZipFile, RuntimeError, EOFError, NotImplementedError) as error:
        raise VerificationError("IPA ZIP is invalid or cannot be safely extracted.") from error


def entitlement_allowed(claimed: object, allowed: object) -> bool:
    """Check a claim against Apple's profile allowlist, without type coercion."""
    if type(claimed) is not type(allowed):
        return False
    if isinstance(claimed, dict):
        return all(key in allowed and entitlement_allowed(value, allowed[key]) for key, value in claimed.items())
    if isinstance(claimed, list):
        return all(any(entitlement_allowed(value, candidate) for candidate in allowed) for value in claimed)
    if isinstance(claimed, str):
        if claimed == allowed:
            return True
        if "*" not in allowed:
            return False
        # Only a terminal '*' grants a prefix. '?' and character classes remain literal.
        return allowed.endswith("*") and allowed.count("*") == 1 and claimed.startswith(allowed[:-1])
    if isinstance(claimed, (bool, int, float, bytes, dt.datetime)):
        return claimed == allowed
    return False


def utc_date(value: object, label: str) -> dt.datetime:
    require(isinstance(value, dt.datetime), f"{label} is missing or invalid.")
    if value.tzinfo is None:
        return value.replace(tzinfo=UTC)
    return value.astimezone(UTC)


def native(command: list[str], label: str, timeout: int = 60) -> subprocess.CompletedProcess:
    """Never echo captured native output: it can contain personal/private data."""
    try:
        result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise VerificationError(f"{label} could not run or timed out.") from error
    require(result.returncode == 0, f"{label} failed.")
    return result


def decode_plist(data: bytes, label: str) -> dict:
    try:
        value = plistlib.loads(data)
    except (ValueError, TypeError, OverflowError, plistlib.InvalidFileException, ExpatError) as error:
        raise VerificationError(f"{label} is not a valid property list.") from error
    require(isinstance(value, dict), f"{label} must be a property-list dictionary.")
    return value


def uuid_value(value: object) -> str:
    require(isinstance(value, str), "Provisioning profile UUID is invalid.")
    try:
        return str(uuid.UUID(value)).upper()
    except (ValueError, AttributeError) as error:
        raise VerificationError("Provisioning profile UUID is invalid.") from error


def verify_profile(profile: dict, args: argparse.Namespace, certificate_sha1: str, now: dt.datetime) -> dict:
    require(uuid_value(profile.get("UUID")) == args.profile_uuid, "Embedded provisioning profile UUID differs from the selected profile.")
    teams = profile.get("TeamIdentifier")
    require(isinstance(teams, list) and teams and all(isinstance(t, str) for t in teams) and args.team_id in teams,
            "Embedded provisioning profile does not allow the selected Team.")
    expiry = utc_date(profile.get("ExpirationDate"), "Provisioning profile expiration")
    require(expiry > now, "Embedded provisioning profile has expired.")
    if "CreationDate" in profile:
        created = utc_date(profile["CreationDate"], "Provisioning profile creation date")
        require(created <= now + dt.timedelta(minutes=5) and created < expiry, "Provisioning profile creation date is invalid.")
    certificates = profile.get("DeveloperCertificates")
    require(isinstance(certificates, list) and certificates and all(isinstance(c, bytes) and c for c in certificates),
            "Provisioning profile has no valid allowed signing certificates.")
    allowed_sha1 = {hashlib.sha1(c).hexdigest().upper() for c in certificates}
    require(certificate_sha1 in allowed_sha1, "Actual signing certificate is not allowed by the embedded provisioning profile.")
    entitlements = profile.get("Entitlements")
    require(isinstance(entitlements, dict), "Provisioning profile entitlements are missing.")
    require(entitlements.get("com.apple.developer.team-identifier") == args.team_id,
            "Provisioning profile entitlement Team differs from the selected Team.")
    prefixes = profile.get("ApplicationIdentifierPrefix")
    require(isinstance(prefixes, list) and prefixes and all(isinstance(p, str) and re.fullmatch(r"[A-Za-z0-9]+", p) for p in prefixes),
            "Provisioning profile application identifier prefixes are invalid.")
    identifiers = [prefix + "." + args.bundle_id for prefix in prefixes]
    require(any(entitlement_allowed(identifier, entitlements.get("application-identifier")) for identifier in identifiers),
            "Provisioning profile does not allow the requested Bundle ID.")
    debug = entitlements.get("get-task-allow")
    require(type(debug) is bool, "Provisioning profile get-task-allow must be a boolean.")
    all_devices = profile.get("ProvisionsAllDevices", False)
    require(type(all_devices) is bool and not all_devices, "Enterprise provisioning is unsupported for this export method.")
    if args.export_method == "app-store-connect":
        require("ProvisionedDevices" not in profile and not debug, "Embedded provisioning profile is not an App Store distribution profile.")
        devices: list[str] = []
    else:
        devices = profile.get("ProvisionedDevices")
        require(isinstance(devices, list) and devices and all(isinstance(d, str) and d for d in devices),
                "Device-restricted provisioning profile has no valid registered devices.")
        require(len(set(devices)) == len(devices), "Provisioning profile contains duplicate registered devices.")
        expected_debug = args.export_method in ("debugging", "development")
        require(debug == expected_debug, "Provisioning profile get-task-allow does not match the export method.")
    if args.device_udid:
        require(bool(devices), "Target device checking requires a device-restricted export method.")
        require(any(d.casefold() == args.device_udid.casefold() for d in devices), "Target device is not registered in the embedded provisioning profile.")
    return {"expiry": expiry, "entitlements": entitlements, "identifiers": identifiers,
            "device_count": len(devices), "debug": debug}


def executable_architectures(executable: Path) -> list[str]:
    """Inspect every supported arm64 slice instead of codesign's default slice."""
    size = executable.stat().st_size
    with executable.open("rb") as source:
        header = source.read(32)
        require(len(header) >= 12, "Application executable has an invalid Mach-O header.")
        magic = header[:4]
        slices: list[tuple[int, int, int, int]] = []
        if magic in (b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf"):
            require(len(header) == 32, "Application executable Mach-O header is truncated.")
            endian = "<" if magic == b"\xcf\xfa\xed\xfe" else ">"
            cpu, subtype = struct.unpack(endian + "II", header[4:12])
            slices.append((cpu, subtype, 0, size))
        elif magic in (b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca", b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca"):
            endian = ">" if magic[:2] == b"\xca\xfe" else "<"
            wide = magic in (b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca")
            count = struct.unpack(endian + "I", header[4:8])[0]
            require(0 < count <= 8, "Application executable has an invalid architecture count.")
            record_size = 32 if wide else 20
            source.seek(8)
            table = source.read(count * record_size)
            require(len(table) == count * record_size, "Application executable architecture table is truncated.")
            for index in range(count):
                record = table[index * record_size:(index + 1) * record_size]
                if wide:
                    cpu, subtype, offset, length, _, _ = struct.unpack(endian + "IIQQII", record)
                else:
                    cpu, subtype, offset, length, _ = struct.unpack(endian + "IIIII", record)
                require(offset >= 8 + len(table) and length >= 32 and offset + length <= size,
                        "Application executable architecture range is invalid.")
                require(all(offset + length <= old_offset or old_offset + old_length <= offset for _, _, old_offset, old_length in slices),
                        "Application executable architecture ranges overlap.")
                source.seek(offset)
                inner = source.read(12)
                require(inner[:4] in (b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf"), "Application executable contains an invalid architecture slice.")
                inner_endian = "<" if inner[:4] == b"\xcf\xfa\xed\xfe" else ">"
                require(struct.unpack(inner_endian + "II", inner[4:12]) == (cpu, subtype), "Application executable slice differs from its architecture table.")
                slices.append((cpu, subtype, offset, length))
        else:
            raise VerificationError("Application executable is not a supported 64-bit Mach-O binary.")
    architectures = []
    for cpu, subtype, _, _ in slices:
        subtype &= 0x00FFFFFF
        require(cpu == 0x0100000C and subtype in (0, 1, 2), "Application executable has an unsupported iPhone architecture.")
        architecture = "arm64e" if subtype == 2 else "arm64"
        require(architecture not in architectures, "Application executable has duplicate architecture slices.")
        architectures.append(architecture)
    return architectures


def signature_field(data: bytes, field: str) -> str:
    decoded = data.decode("utf-8", errors="replace")
    values = re.findall(r"^" + re.escape(field) + r"=([^\r\n]*)$", decoded, re.MULTILINE)
    require(len(values) == 1, "Code signature identity metadata is missing or ambiguous.")
    return values[0]


def verify_certificate_dates(certificate: Path, now: dt.datetime) -> None:
    output = native(["/usr/bin/openssl", "x509", "-inform", "DER", "-in", str(certificate), "-noout", "-startdate", "-enddate"],
                    "Signing certificate date inspection").stdout
    try:
        dates = dict(line.split("=", 1) for line in output.decode("ascii").splitlines())
        start = dt.datetime.strptime(dates["notBefore"], "%b %d %H:%M:%S %Y %Z").replace(tzinfo=UTC)
        end = dt.datetime.strptime(dates["notAfter"], "%b %d %H:%M:%S %Y %Z").replace(tzinfo=UTC)
    except (UnicodeError, ValueError, KeyError) as error:
        raise VerificationError("Signing certificate dates are invalid.") from error
    require(start <= now < end, "Actual signing certificate is not currently valid.")


def verify(ipa: Path, args: argparse.Namespace, work: Path) -> dict:
    original_ipa_hash = sha256_file(ipa)
    extracted = work / "extracted"
    extracted.mkdir()
    safe_extract(ipa, extracted)
    payload = extracted / "Payload"
    require(payload.is_dir(), "IPA has no Payload directory.")
    apps = [p for p in payload.iterdir() if p.is_dir() and p.suffix.casefold() == ".app"]
    require(len(apps) == 1, "IPA must contain exactly one top-level application.")
    app = apps[0]
    require(not any(p != app and p.is_dir() and p.suffix.casefold() in (".appex", ".app", ".xpc") for p in payload.rglob("*")),
            "IPA contains an unmapped extension or nested application target.")
    embedded = app / "embedded.mobileprovision"
    require(embedded.is_file(), "Application has no embedded provisioning profile.")
    require(not any(p != embedded for p in app.rglob("embedded.mobileprovision")), "IPA contains an unmapped nested provisioning profile.")
    require((app / "Info.plist").is_file(), "Application Info.plist is missing.")
    info = decode_plist((app / "Info.plist").read_bytes(), "Application Info.plist")
    require(info.get("CFBundleIdentifier") == args.bundle_id, "IPA Bundle ID differs from the requested Bundle ID.")
    require(info.get("CFBundlePackageType") == "APPL", "IPA bundle is not an application.")
    executable_name = info.get("CFBundleExecutable")
    require(isinstance(executable_name, str) and executable_name and executable_name not in (".", "..")
            and not any(c in executable_name for c in ("/", "\\", ":", "\x00")), "Application executable name is invalid.")
    executable = app / executable_name
    require(executable.is_file(), "Application executable is missing.")
    architectures = executable_architectures(executable)
    for key in ("CFBundleShortVersionString", "CFBundleVersion"):
        require(isinstance(info.get(key), str) and bool(info[key]) and len(info[key]) <= 128
                and not any(ord(c) < 32 for c in info[key]), "Application version or build metadata is invalid.")
    native(["/usr/bin/codesign", "--verify", "--deep", "--strict", "--all-architectures", str(app)],
           "Strict application code-signature verification", timeout=120)
    profile_bytes = embedded.read_bytes()
    profile_hash = hashlib.sha256(profile_bytes).hexdigest()
    if args.profile_sha256:
        require(profile_hash == args.profile_sha256, "Embedded provisioning profile differs from the selected profile bytes.")
    decoded = native(["/usr/bin/security", "cms", "-D", "-i", str(embedded)], "Embedded provisioning profile decoding").stdout
    profile = decode_plist(decoded, "Embedded provisioning profile")
    now = dt.datetime.now(UTC)
    profile_details = None
    for architecture in architectures:
        display = native(["/usr/bin/codesign", "--display", "--verbose=4", "--architecture", architecture, str(app)], "Code signature metadata inspection")
        signature = display.stdout + b"\n" + display.stderr
        require(signature_field(signature, "TeamIdentifier") == args.team_id, "Actual code signature Team differs from the selected Team.")
        require(signature_field(signature, "Identifier") == args.bundle_id, "Actual code signature identifier differs from the requested Bundle ID.")
        prefix = work / ("certificate-" + architecture + "-")
        native(["/usr/bin/codesign", "--display", "--architecture", architecture, "--extract-certificates=" + str(prefix), str(app)],
               "Actual signing certificate extraction")
        certificate = Path(str(prefix) + "0")
        require(certificate.is_file() and 0 < certificate.stat().st_size <= 1024 * 1024, "Actual signing certificate was not extracted.")
        actual_sha1 = hashlib.sha1(certificate.read_bytes()).hexdigest().upper()
        require(actual_sha1 == args.certificate_sha1, "Actual signing certificate differs from the selected identity.")
        verify_certificate_dates(certificate, now)
        profile_details = verify_profile(profile, args, actual_sha1, now)
        claimed_bytes = native(["/usr/bin/codesign", "--display", "--architecture", architecture, "--entitlements", ":-", str(app)],
                               "Signed entitlement inspection").stdout
        claimed = decode_plist(claimed_bytes, "Signed entitlements")
        require(claimed.get("com.apple.developer.team-identifier") == args.team_id, "Signed entitlement Team differs from the selected Team.")
        require(claimed.get("application-identifier") in profile_details["identifiers"],
                "Signed application identifier does not match the profile prefix and requested Bundle ID.")
        require(entitlement_allowed(claimed, profile_details["entitlements"]), "Signed entitlements exceed the embedded provisioning profile allowlist.")
        claimed_debug = claimed.get("get-task-allow", False)
        require(type(claimed_debug) is bool and claimed_debug == profile_details["debug"], "Signed get-task-allow does not match the export method.")
    require(profile_details is not None, "Application has no verifiable architecture.")
    require(sha256_file(ipa) == original_ipa_hash, "IPA file changed during verification.")
    checks = {
        "codesignVerified": True, "allArchitecturesChecked": True, "noUnmappedTargets": True,
        "bundleMatchesRequested": True, "signatureTeamMatchesRequested": True,
        "certificateMatchesRequested": True, "certificateCurrentlyValid": True,
        "certificateAllowedByProfile": True, "profileUUIDMatchesRequested": True,
        "profileTeamMatchesRequested": True, "profileNotExpired": True,
        "applicationIdentifierAllowed": True, "entitlementsAllowed": True, "exportMethodMatches": True,
    }
    if args.profile_sha256:
        checks["profileHashMatchesRequested"] = True
    result = {
        "bundleId": args.bundle_id, "teamId": args.team_id,
        "version": info["CFBundleShortVersionString"], "build": info["CFBundleVersion"],
        "profileUUID": args.profile_uuid, "profileExpiresAt": profile_details["expiry"].isoformat().replace("+00:00", "Z"),
        "profileSHA256": profile_hash, "certificateSHA1": args.certificate_sha1,
        "ipaSHA256": original_ipa_hash, "exportMethod": args.export_method,
        "architectures": architectures, "deviceCount": profile_details["device_count"],
        "targetDeviceChecked": bool(args.device_udid), "checks": checks,
    }
    if args.device_udid:
        result["targetDeviceContained"] = True
    return result


def write_metadata(output: Path, metadata: dict) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=".ipa-verification-", dir=output.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as destination:
            json.dump(metadata, destination, indent=2, sort_keys=True, ensure_ascii=True)
            destination.write("\n")
            destination.flush()
            os.fsync(destination.fileno())
        # An atomic, no-clobber publication also rejects existing symlink outputs.
        os.link(temporary, output)
    finally:
        Path(temporary).unlink(missing_ok=True)


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("--ipa", type=Path, required=True)
    result.add_argument("--bundle-id", required=True)
    result.add_argument("--team-id", required=True)
    result.add_argument("--certificate-sha1", required=True, help="Selected signing identity's 40-digit SHA1 fingerprint")
    result.add_argument("--profile-uuid", required=True)
    result.add_argument("--profile-sha256", help="Optional SHA256 of the selected provisioning profile's CMS bytes")
    result.add_argument("--export-method", choices=EXPORT_METHODS, required=True)
    result.add_argument("--output", type=Path, required=True, help="New JSON metadata path; existing files are never overwritten")
    result.add_argument("--device-udid", help="Optional target device identifier; never included in output")
    return result


def main() -> int:
    args = parser().parse_args()
    try:
        require(sys.platform == "darwin", "IPA signing verification requires macOS with codesign, security, and openssl; no signing checks ran.")
        require(re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9-]*(?:\.[A-Za-z0-9][A-Za-z0-9-]*)+", args.bundle_id) is not None,
                "Requested Bundle ID is invalid.")
        require(re.fullmatch(r"[A-Z0-9]{10}", args.team_id) is not None, "Requested Team ID must contain 10 uppercase letters or digits.")
        require(re.fullmatch(r"[A-Fa-f0-9]{40}", args.certificate_sha1) is not None, "Requested certificate SHA1 must contain exactly 40 hexadecimal digits.")
        args.certificate_sha1 = args.certificate_sha1.upper()
        args.profile_uuid = uuid_value(args.profile_uuid)
        if args.profile_sha256:
            require(re.fullmatch(r"[A-Fa-f0-9]{64}", args.profile_sha256) is not None, "Requested profile SHA256 must contain exactly 64 hexadecimal digits.")
            args.profile_sha256 = args.profile_sha256.lower()
        if args.device_udid:
            require(re.fullmatch(r"[A-Fa-f0-9-]{8,64}", args.device_udid) is not None, "Target device identifier has an invalid format.")
        require(args.ipa.is_file(), "Requested IPA file does not exist.")
        require(not args.output.exists() and not args.output.is_symlink(), "Output metadata path already exists; choose a new path.")
        for tool in ("/usr/bin/codesign", "/usr/bin/security", "/usr/bin/openssl"):
            require(Path(tool).is_file() and os.access(tool, os.X_OK), "Required macOS signing tool is unavailable.")
        with tempfile.TemporaryDirectory(prefix="y3-verify-ipa-") as directory:
            metadata = verify(args.ipa, args, Path(directory))
        write_metadata(args.output, metadata)
        print("IPA signature, identity, profile, and entitlements verified; sanitized metadata written.")
        return 0
    except VerificationError as error:
        print(f"IPA verification failed: {error}", file=sys.stderr)
        return 1
    except (OSError, ValueError, OverflowError, RecursionError, struct.error, zipfile.LargeZipFile):
        print("IPA verification failed: a required file or verification structure could not be processed; no new metadata was published.", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
