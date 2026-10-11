#!/bin/bash
# Encrypt the verified IPA and report before publishing a public CI artifact.
set -euo pipefail
umask 077

fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }

script_directory="$(cd "$(dirname "$0")" && pwd)"
[[ $# -eq 0 ]] || fail "This helper accepts input paths through its environment."
[[ -n "${RUNNER_TEMP:-}" && "$RUNNER_TEMP" == /* && -d "$RUNNER_TEMP" ]] || fail "RUNNER_TEMP must be an existing absolute temporary directory."
[[ -n "${IPA_PATH:-}" && -n "${VERIFICATION_PATH:-}" ]] || fail "IPA_PATH and VERIFICATION_PATH must identify the verified build outputs."
recipient_file="${DELIVERY_RECIPIENT_FILE:-$script_directory/../delivery-recipient.txt}"
command -v python3 >/dev/null 2>&1 || fail "python3 is required."
command -v curl >/dev/null 2>&1 || fail "curl is required."
command -v tar >/dev/null 2>&1 || fail "tar is required."

# Digests from the official v1.3.2 GitHub release asset metadata:
# https://api.github.com/repos/FiloSottile/age/releases/tags/v1.3.2
# The version and bytes stay fixed even when the upstream latest release changes.
age_version="1.3.2"
case "$(uname -s):$(uname -m)" in
    Darwin:x86_64)
        age_platform="darwin-amd64"
        age_sha256="1d1e4bc66e1427edad7739ae7616157de0e79db8b6d2a1497d7d9925fb06a539"
        ;;
    Darwin:arm64)
        age_platform="darwin-arm64"
        age_sha256="e2020b073c44f692685a24d6abc378817eb81ffaaf49fd0531ef8565f767f2f5"
        ;;
    Linux:x86_64)
        age_platform="linux-amd64"
        age_sha256="cbe24006683f8eb669266162894b9a522a1af52f2665fbc63a4bb032ed26ac10"
        ;;
    *) fail "This age release is pinned for macOS arm64/amd64 and Linux amd64."
        ;;
esac

task_directory="$(mktemp -d "$RUNNER_TEMP/y3pos-encrypt.XXXXXX")"
cleanup() { rm -rf "$task_directory"; }
trap 'task_status=$?; trap - EXIT; cleanup; exit "$task_status"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

# Read only a public age recipient; private transport identities never enter CI.
recipient="$(python3 - "$recipient_file" <<'PY'
from pathlib import Path
import re
import sys
try:
    path = Path(sys.argv[1])
    if path.is_symlink() or not path.is_file() or path.stat().st_size > 256:
        raise ValueError()
    recipient = path.read_text(encoding="ascii").strip()
    if not re.fullmatch(r"age1[qpzry9x8gf2tvdw0s3jn54khce6mua7l]{58}", recipient):
        raise ValueError()
    print(recipient)
except (OSError, UnicodeError, ValueError):
    sys.exit("Error: delivery-recipient.txt must contain exactly one public age recipient.")
PY
)" || exit 1

cache_directory="$RUNNER_TEMP/y3pos-age/$age_version/$age_platform"
mkdir -p "$cache_directory"
archive_path="$cache_directory/age.tar.gz"
check_archive() {
    python3 - "$archive_path" "$age_sha256" <<'PY'
import hashlib
from pathlib import Path
import sys
path = Path(sys.argv[1])
if path.is_symlink() or not path.is_file():
    sys.exit(1)
digest = hashlib.sha256()
with path.open("rb") as source:
    for block in iter(lambda: source.read(1024 * 1024), b""):
        digest.update(block)
sys.exit(0 if digest.hexdigest() == sys.argv[2] else 1)
PY
}
if ! check_archive; then
    archive_url="https://github.com/FiloSottile/age/releases/download/v$age_version/age-v$age_version-$age_platform.tar.gz"
    if ! curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
        --connect-timeout 20 --max-time 120 "$archive_url" -o "$task_directory/age.tar.gz"; then
        fail "The pinned official age release could not be downloaded."
    fi
    # Verify before placing the archive in the reusable runner-local cache.
    python3 - "$task_directory/age.tar.gz" "$age_sha256" <<'PY'
import hashlib
from pathlib import Path
import sys
if hashlib.sha256(Path(sys.argv[1]).read_bytes()).hexdigest() != sys.argv[2]:
    sys.exit("Error: The official age release asset failed its pinned SHA-256 check.")
PY
    [[ ! -L "$archive_path" ]] || fail "The age cache path is a symlink."
    mv -f "$task_directory/age.tar.gz" "$archive_path"
fi
check_archive || fail "The cached age release failed its pinned SHA-256 check."
tar -xzf "$archive_path" -C "$task_directory" age/age
age_binary="$task_directory/age/age"
[[ -f "$age_binary" && ! -L "$age_binary" ]] || fail "The official age binary is missing."
actual_version="$("$age_binary" --version)"
[[ "$actual_version" == "v$age_version" || "$actual_version" == "$age_version" ]] || fail "The extracted age binary has an unexpected version."

# Package two explicit build outputs, never the signing or export directory.
python3 - "$IPA_PATH" "$VERIFICATION_PATH" "$task_directory/delivery.zip" <<'PY'
import hashlib
import json
from pathlib import Path
import sys
import zipfile
try:
    ipa, report, archive = map(Path, sys.argv[1:])
    if any(path.is_symlink() or not path.is_file() for path in (ipa, report)):
        raise ValueError()
    if ipa.suffix != ".ipa" or ipa.stat().st_size == 0 or report.stat().st_size > 1024 * 1024:
        raise ValueError()
    metadata = json.loads(report.read_text(encoding="utf-8"))
    checks = metadata.get("checks", {})
    required = ("codesignVerified", "bundleMatchesRequested", "signatureTeamMatchesRequested", "certificateMatchesRequested")
    if not isinstance(checks, dict) or not all(checks.get(key) is True for key in required) or any(value is not True for value in checks.values()):
        raise ValueError()
    digest = hashlib.sha256()
    with ipa.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    if metadata.get("ipaSHA256") != digest.hexdigest():
        raise ValueError()
    with zipfile.ZipFile(archive, "x", compression=zipfile.ZIP_DEFLATED) as delivery:
        delivery.write(ipa, "Y3POSClient.ipa")
        delivery.write(report, "verification.json")
except (OSError, UnicodeError, ValueError, TypeError, AttributeError):
    sys.exit("Error: Build outputs must include a verified IPA and its matching successful verification report.")
PY
"$age_binary" --encrypt --recipient "$recipient" \
    --output "$task_directory/delivery.zip.age" "$task_directory/delivery.zip"
delivery_directory="$RUNNER_TEMP/y3pos-encrypted-delivery"
mkdir -p "$delivery_directory"
encrypted_path="$delivery_directory/Y3POSClient.zip.age"
python3 - "$task_directory/delivery.zip.age" "$encrypted_path" <<'PY'
import os
from pathlib import Path
import sys
try:
    source, output = map(Path, sys.argv[1:])
    if not source.is_file() or source.stat().st_size == 0:
        raise ValueError()
    # Atomic publication fails if any file or symlink already uses the output name.
    os.link(source, output)
except (OSError, ValueError):
    sys.exit("Error: Encrypted delivery could not be published to a new output path.")
PY
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    printf 'encrypted_path=%s\n' "$encrypted_path" >>"$GITHUB_OUTPUT"
fi
printf 'Verified IPA and verification JSON encrypted with age v%s for private delivery.\n' "$age_version"
