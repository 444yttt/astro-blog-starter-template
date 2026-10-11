#!/bin/bash
# Hosted macOS CI: restore existing signing assets, sign this app, export locally.
set -euo pipefail
umask 077

fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }

show_build_diagnostics() {
    python3 - "$1" "${RUNNER_TEMP:-}" <<'PY'
import os
import pathlib
import plistlib
import re
import sys
secret_names = ("BUILD_CERTIFICATE_BASE64", "P12_PASSWORD", "KEYCHAIN_PASSWORD",
                "BUILD_PROVISION_PROFILE_BASE64", "ASC_PRIVATE_KEY", "ASC_KEY_ID", "ASC_ISSUER_ID", "APPLE_TEAM_ID")
secrets = [os.environ[name] for name in secret_names if os.environ.get(name)]
if sys.argv[2]:
    signing = pathlib.Path(sys.argv[2]) / "y3pos-signing"
    identity_log = signing / "identities.txt"
    if identity_log.is_file():
        secrets.extend(re.findall(r'"([^"\n]+)"', identity_log.read_text(errors="replace")))
    profile_path = signing / "profile.plist"
    if profile_path.is_file():
        try:
            profile = plistlib.loads(profile_path.read_bytes())
            secrets.extend(value for value in (profile.get("Name"), profile.get("UUID")) if isinstance(value, str) and value)
            secrets.extend(value for value in profile.get("ApplicationIdentifierPrefix", []) if isinstance(value, str) and value)
        except (OSError, ValueError):
            pass
secrets = sorted(set(secrets), key=len, reverse=True)
lines = pathlib.Path(sys.argv[1]).read_text(errors="replace").splitlines()
diagnostics = [line for line in lines if re.search(r"\b(?:error|warning):", line, re.I)]
print("Apple build diagnostics:", file=sys.stderr)
if not diagnostics:
    print("No compiler/signing diagnostic line was emitted; the build command failed.", file=sys.stderr)
for line in diagnostics[-40:]:
    for value in secrets:
        line = line.replace(value, "[REDACTED]")
    if sys.argv[2]:
        line = line.replace(sys.argv[2], "<runner-temp>")
    print(line[:1600], file=sys.stderr)
PY
}

script_directory="$(cd "$(dirname "$0")" && pwd)"
project_directory="$(cd "$script_directory/.." && pwd)"
project_path="$project_directory/Y3Client.xcodeproj"
bundle_id="com.ayato.y3posclient"
[[ -n "${RUNNER_TEMP:-}" && "$RUNNER_TEMP" == /* ]] || fail "RUNNER_TEMP must identify the hosted runner's absolute temporary directory."
signing_directory="$RUNNER_TEMP/y3pos-signing"
output_directory="$RUNNER_TEMP/y3pos-output"
keychain_path="$signing_directory/signing.keychain-db"

cleanup() {
    if [[ -f "$signing_directory/original-project.pbxproj" && -d "$project_path" ]]; then
        cp "$signing_directory/original-project.pbxproj" "$project_path/project.pbxproj" || true
    fi
    if [[ -f "$signing_directory/installed-profiles.txt" ]]; then
        while IFS= read -r installed_profile; do
            [[ -n "$installed_profile" ]] && rm -f "$installed_profile" || true
        done < "$signing_directory/installed-profiles.txt"
    fi
    if [[ -f "$signing_directory/original-keychains.json" ]]; then
        python3 - "$signing_directory/original-keychains.json" <<'PY' || true
import json
import subprocess
import sys
with open(sys.argv[1], encoding="utf-8") as source:
    paths = json.load(source)
subprocess.run(["/usr/bin/security", "list-keychains", "-d", "user", "-s", *paths],
               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
PY
    fi
    if [[ -f "$keychain_path" ]]; then
        /usr/bin/security delete-keychain "$keychain_path" >/dev/null 2>&1 || true
    fi
    [[ ! -d "$signing_directory" ]] || rm -rf "$signing_directory"
}

if [[ "${1:-}" == --cleanup-only && $# -eq 1 ]]; then
    cleanup
    # This final workflow step runs after encrypted artifact upload. The normal
    # EXIT trap preserves outputs long enough for the encryption step to read.
    [[ ! -d "$output_directory" ]] || rm -rf "$output_directory"
    exit 0
fi
[[ $# -eq 0 ]] || fail "This CI helper accepts no options, except --cleanup-only."
[[ "$(uname -s)" == Darwin ]] || fail "This helper requires the macOS GitHub Actions runner."
[[ -d "$project_path" ]] || fail "Y3Client.xcodeproj is missing from the checked-out client."
[[ ! -e "$signing_directory" && ! -e "$output_directory" ]] || fail "Signing/output temporary directories already exist; refusing to overwrite them."

for required_name in BUILD_CERTIFICATE_BASE64 P12_PASSWORD APPLE_TEAM_ID; do
    [[ -n "${!required_name:-}" ]] || fail "Required GitHub Actions secret is unavailable: $required_name. Existing repository aliases are supported by the workflow."
done
[[ "$APPLE_TEAM_ID" =~ ^[A-Z0-9]{10}$ ]] || fail "APPLE_TEAM_ID is not a valid Apple Team ID."
if [[ -z "${BUILD_PROVISION_PROFILE_BASE64:-}" ]]; then
    for required_name in ASC_KEY_ID ASC_ISSUER_ID ASC_PRIVATE_KEY; do
        [[ -n "${!required_name:-}" ]] || fail "No new-client provisioning profile is supplied, and App Store Connect secret $required_name is unavailable."
    done
    [[ -f "$script_directory/prepare-ci-profile.py" ]] || fail "The App Store Connect profile bootstrap helper is missing."
fi
[[ -f "$script_directory/verify-ipa.py" ]] || fail "The signed IPA verification helper is missing."

xcode_version="$(xcodebuild -version 2>/dev/null)" || fail "Full Xcode is unavailable."
printf '%s\n' "$xcode_version"
xcode_release="$(printf '%s\n' "$xcode_version" | sed -n 's/^Xcode //p')"
[[ "$xcode_release" == 16.4 ]] || fail "This workflow requires the pinned Xcode 16.4; check DEVELOPER_DIR and the runner image."
xcrun --sdk iphoneos --show-sdk-path >/dev/null 2>&1 || fail "The iOS SDK is missing."
xcrun --sdk iphonesimulator --show-sdk-path >/dev/null 2>&1 || fail "The iOS Simulator SDK is missing."
command -v python3 >/dev/null 2>&1 || fail "python3 is required."
mkdir "$signing_directory" "$output_directory"
trap 'task_status=$?; trap - EXIT; cleanup; exit "$task_status"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

printf 'Checking the final source with the iOS Simulator SDK...\n'
if ! xcodebuild -quiet -project "$project_path" -scheme Y3Client -configuration Debug \
    -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath "$signing_directory/SimulatorDerivedData" \
    CODE_SIGNING_ALLOWED=NO build >"$output_directory/simulator-build.log" 2>&1; then
    show_build_diagnostics "$output_directory/simulator-build.log"
    fail "The Apple SDK simulator build failed. No signing or export was attempted."
fi

python3 - "$signing_directory" <<'PY'
import base64
import os
import pathlib
import sys
directory = pathlib.Path(sys.argv[1])
try:
    certificate = base64.b64decode("".join(os.environ["BUILD_CERTIFICATE_BASE64"].split()), validate=True)
    if not certificate:
        raise ValueError()
    (directory / "certificate.p12").write_bytes(certificate)
    profile = os.environ.get("BUILD_PROVISION_PROFILE_BASE64", "")
    if profile:
        content = base64.b64decode("".join(profile.split()), validate=True)
        if not content:
            raise ValueError()
        (directory / "Y3POSClient.mobileprovision").write_bytes(content)
    else:
        key = os.environ["ASC_PRIVATE_KEY"].replace("\\n", "\n").strip() + "\n"
        if "-----BEGIN PRIVATE KEY-----" not in key or "-----END PRIVATE KEY-----" not in key:
            raise ValueError()
        (directory / "AuthKey.p8").write_text(key, encoding="utf-8")
except (KeyError, ValueError):
    print("Error: Signing certificate, profile, or ASC private-key secret has invalid encoding.", file=sys.stderr)
    sys.exit(1)
for path in directory.iterdir():
    if path.is_file():
        path.chmod(0o600)
PY
unset BUILD_CERTIFICATE_BASE64 BUILD_PROVISION_PROFILE_BASE64 ASC_PRIVATE_KEY

if [[ -z "${KEYCHAIN_PASSWORD:-}" ]]; then
    KEYCHAIN_PASSWORD="$(/usr/bin/openssl rand -base64 32)"
    printf '::add-mask::%s\n' "$KEYCHAIN_PASSWORD"
fi
printf '%s' "$KEYCHAIN_PASSWORD" >"$signing_directory/keychain-password"
python3 - "$signing_directory/original-keychains.json" <<'PY'
import json
import shlex
import subprocess
import sys
result = subprocess.run(["/usr/bin/security", "list-keychains", "-d", "user"],
                        check=True, capture_output=True, text=True)
with open(sys.argv[1], "w", encoding="utf-8") as target:
    json.dump(shlex.split(result.stdout), target)
PY
if ! /usr/bin/security create-keychain -p "$KEYCHAIN_PASSWORD" "$keychain_path" \
    >"$signing_directory/keychain.log" 2>&1; then
    fail "Could not create the temporary signing keychain."
fi
/usr/bin/security set-keychain-settings -lut 21600 "$keychain_path"
/usr/bin/security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$keychain_path"
if ! /usr/bin/security import "$signing_directory/certificate.p12" -P "$P12_PASSWORD" \
    -t cert -f pkcs12 -k "$keychain_path" -T /usr/bin/codesign -T /usr/bin/security \
    >"$signing_directory/import.log" 2>&1; then
    fail "The existing P12 could not be imported with its password."
fi
unset P12_PASSWORD
if ! /usr/bin/security set-key-partition-list -S apple-tool:,apple:,codesign: -s \
    -k "$KEYCHAIN_PASSWORD" "$keychain_path" >"$signing_directory/key-access.log" 2>&1; then
    fail "The imported private key could not be granted noninteractive codesign access."
fi
unset KEYCHAIN_PASSWORD
python3 - "$signing_directory/original-keychains.json" "$keychain_path" <<'PY'
import json
import subprocess
import sys
with open(sys.argv[1], encoding="utf-8") as source:
    paths = json.load(source)
subprocess.run(["/usr/bin/security", "list-keychains", "-d", "user", "-s", sys.argv[2], *paths],
               check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
PY
/usr/bin/security find-identity -v -p codesigning "$keychain_path" >"$signing_directory/identities.txt"
/usr/bin/security find-certificate -a -p "$keychain_path" >"$signing_directory/certificates.pem"
certificate_sha1="$(python3 - "$signing_directory" "$APPLE_TEAM_ID" <<'PY'
import hashlib
import pathlib
import re
import subprocess
import sys
directory, team = pathlib.Path(sys.argv[1]), sys.argv[2]
identities = set(re.findall(r"(?m)^\s*\d+\)\s+([0-9A-Fa-f]{40})\s", (directory / "identities.txt").read_text()))
identities = {value.upper() for value in identities}
if len(identities) != 1:
    sys.exit("Error: The P12 must contain exactly one valid codesigning identity with its private key.")
fingerprint = identities.pop()
for pem in re.findall(br"-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----", (directory / "certificates.pem").read_bytes(), re.S):
    result = subprocess.run(["/usr/bin/openssl", "x509", "-inform", "PEM", "-outform", "DER"],
                            input=pem, capture_output=True, check=True)
    if hashlib.sha1(result.stdout).hexdigest().upper() != fingerprint:
        continue
    subject = subprocess.run(["/usr/bin/openssl", "x509", "-inform", "DER", "-subject", "-nameopt", "RFC2253", "-noout"],
                             input=result.stdout, capture_output=True, check=True).stdout.decode()
    if not re.search(r"(?:^|[,\s])OU=" + re.escape(team) + r"(?:,|\s|$)", subject):
        sys.exit("Error: The imported signing certificate belongs to a different Apple team.")
    (directory / "signing-certificate.cer").write_bytes(result.stdout)
    print(fingerprint)
    break
else:
    sys.exit("Error: The valid private-key identity's public certificate could not be extracted.")
PY
)" || exit 1

profile_path="$signing_directory/Y3POSClient.mobileprovision"
if [[ ! -f "$profile_path" ]]; then
    printf 'Preparing a profile for the new client with the existing ASC key...\n'
    ASC_KEY_PATH="$signing_directory/AuthKey.p8" python3 "$script_directory/prepare-ci-profile.py" \
        --certificate-der "$signing_directory/signing-certificate.cer" \
        --output-profile "$profile_path" --bundle-id "$bundle_id" \
        --team-id "$APPLE_TEAM_ID" --output-metadata "$signing_directory/profile-metadata.json"
fi
if ! /usr/bin/security cms -D -i "$profile_path" >"$signing_directory/profile.plist" \
    2>"$signing_directory/profile-decode.log"; then
    fail "The new-client provisioning profile could not be decoded."
fi
/usr/bin/plutil -convert json -o "$signing_directory/project.json" "$project_path/project.pbxproj"
cp "$project_path/project.pbxproj" "$signing_directory/original-project.pbxproj"

profile_uuid="$(python3 - "$signing_directory" "$project_path/project.pbxproj" "$bundle_id" "$APPLE_TEAM_ID" "$certificate_sha1" <<'PY'
import datetime
import hashlib
import json
import pathlib
import plistlib
import re
import sys
import uuid
directory, project_path = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
bundle, team, certificate = sys.argv[3:]
profile = plistlib.loads((directory / "profile.plist").read_bytes())
def require(condition, message):
    if not condition:
        sys.exit("Error: " + message)
require(profile.get("TeamIdentifier") == [team], "The new-client profile belongs to a different Apple team.")
expiration = profile.get("ExpirationDate")
require(isinstance(expiration, datetime.datetime), "The provisioning profile has no expiry date.")
if expiration.tzinfo is None:
    expiration = expiration.replace(tzinfo=datetime.timezone.utc)
require(expiration > datetime.datetime.now(datetime.timezone.utc), "The new-client provisioning profile is expired.")
require("ProvisionedDevices" not in profile and not profile.get("ProvisionsAllDevices"), "This workflow requires an App Store distribution profile; it does not silently change delivery method.")
entitlements = profile.get("Entitlements", {})
require(entitlements.get("get-task-allow") is False, "The profile is not a distribution profile.")
require(entitlements.get("com.apple.developer.team-identifier") == team, "The profile's team entitlement differs from the selected team.")
identifier = entitlements.get("application-identifier", "")
require(isinstance(identifier, str) and "." in identifier, "The profile has no valid application identifier.")
prefix, allowed_bundle = identifier.split(".", 1)
require(prefix in profile.get("ApplicationIdentifierPrefix", []), "The profile's App ID prefix is inconsistent.")
require(allowed_bundle == bundle or (allowed_bundle.endswith("*") and bundle.startswith(allowed_bundle[:-1])), "The provisioning profile does not authorize the new client's bundle identifier.")
allowed_certificates = {hashlib.sha1(value).hexdigest().upper() for value in profile.get("DeveloperCertificates", [])}
require(certificate in allowed_certificates, "The profile does not authorize the imported certificate/private-key identity.")
profile_uuid = profile.get("UUID", "")
try:
    uuid.UUID(profile_uuid)
except (ValueError, TypeError, AttributeError):
    sys.exit("Error: The provisioning profile has no valid UUID.")
project = json.loads((directory / "project.json").read_text())
objects = project["objects"]
targets = [value for value in objects.values() if value.get("isa") == "PBXNativeTarget"]
require(len(targets) == 1 and targets[0].get("name") == "Y3Client" and targets[0].get("productType") == "com.apple.product-type.application", "The project contains an unexpected or unmapped target; each app/extension needs its own signing configuration.")
target = targets[0]
for config_id in objects[target["buildConfigurationList"]]["buildConfigurations"]:
    settings = objects[config_id]["buildSettings"]
    require(settings.get("PRODUCT_BUNDLE_IDENTIFIER") == bundle, "The app target's source bundle identifier differs from the approved new-client bundle.")
    settings.update({
        "CODE_SIGN_STYLE": "Manual",
        "DEVELOPMENT_TEAM": team,
        "CODE_SIGN_IDENTITY": certificate,
        "PROVISIONING_PROFILE_SPECIFIER": profile_uuid,
        "PROVISIONING_PROFILE": profile_uuid,
    })
def serialize(value, depth=0):
    indentation = "\t" * depth
    if isinstance(value, dict):
        return "{\n" + "".join("\t" * (depth + 1) + json.dumps(str(key), ensure_ascii=False) + " = " + serialize(item, depth + 1) + ";\n" for key, item in value.items()) + indentation + "}"
    if isinstance(value, list):
        return "(\n" + "".join("\t" * (depth + 1) + serialize(item, depth + 1) + ",\n" for item in value) + indentation + ")"
    if isinstance(value, bool):
        return "YES" if value else "NO"
    if isinstance(value, (int, float)):
        return str(value)
    return json.dumps(str(value), ensure_ascii=False)
project_path.write_text("// !$*UTF8*$!\n" + serialize(project) + "\n", encoding="utf-8")
options = {
    "method": "app-store-connect", "destination": "export", "signingStyle": "manual",
    "teamID": team, "signingCertificate": certificate,
    "provisioningProfiles": {bundle: profile_uuid},
    "manageAppVersionAndBuildNumber": False, "stripSwiftSymbols": True,
}
with (directory / "ExportOptions.plist").open("wb") as target_file:
    plistlib.dump(options, target_file)
(directory / "profile-sha256.txt").write_text(hashlib.sha256((directory / "Y3POSClient.mobileprovision").read_bytes()).hexdigest())
print(profile_uuid)
PY
)" || exit 1

profile_directories=("$HOME/Library/MobileDevice/Provisioning Profiles" "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles")
for profile_directory in "${profile_directories[@]}"; do
    mkdir -p "$profile_directory"
    installed_profile="$profile_directory/$profile_uuid.mobileprovision"
    [[ ! -e "$installed_profile" ]] || fail "The selected profile UUID already exists on this runner; refusing to overwrite it."
    printf '%s\n' "$installed_profile" >>"$signing_directory/installed-profiles.txt"
    cp "$profile_path" "$installed_profile"
done

printf 'Archiving the client with the existing distribution private key...\n'
archive_path="$output_directory/Y3POSClient.xcarchive"
if ! xcodebuild -quiet -project "$project_path" -scheme Y3Client -configuration Release \
    -sdk iphoneos -destination 'generic/platform=iOS' \
    -derivedDataPath "$signing_directory/DeviceDerivedData" -archivePath "$archive_path" \
    archive >"$output_directory/archive.log" 2>&1; then
    show_build_diagnostics "$output_directory/archive.log"
    fail "Manual archive/signing failed. No IPA was delivered."
fi
printf 'Exporting the signed IPA locally; no publication is performed...\n'
if ! xcodebuild -quiet -exportArchive -archivePath "$archive_path" \
    -exportPath "$output_directory/export" -exportOptionsPlist "$signing_directory/ExportOptions.plist" \
    >"$output_directory/export.log" 2>&1; then
    show_build_diagnostics "$output_directory/export.log"
    fail "Local signed IPA export failed. An archive is not a delivered IPA."
fi
ipa_paths=("$output_directory/export/"*.ipa)
[[ ${#ipa_paths[@]} -eq 1 && -f "${ipa_paths[0]}" ]] || fail "Export did not produce exactly one signed IPA."
ipa_path="${ipa_paths[0]}"
profile_sha256="$(cat "$signing_directory/profile-sha256.txt")"
verification_path="$output_directory/verification.json"
python3 "$script_directory/verify-ipa.py" --ipa "$ipa_path" --bundle-id "$bundle_id" \
    --team-id "$APPLE_TEAM_ID" --certificate-sha1 "$certificate_sha1" \
    --profile-uuid "$profile_uuid" --profile-sha256 "$profile_sha256" \
    --export-method app-store-connect --output "$verification_path"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    printf 'ipa_path=%s\nverification_path=%s\n' "$ipa_path" "$verification_path" >>"$GITHUB_OUTPUT"
fi
printf 'Signed IPA and its verification report are ready. This App Store distribution IPA is not a direct-install Ad Hoc package.\n'
