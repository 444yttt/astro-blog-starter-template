#!/bin/bash
# Use the existing Xcode account and keychain on a Mac. Never imports keys.
set -euo pipefail
umask 077

usage() {
    cat <<'USAGE'
Usage:
  ./scripts/sign-and-export.sh --reference-project "/path/Y3Manual.xcodeproj"
  ./scripts/sign-and-export.sh --team YOUR_TEAM_ID

Options:
  --reference-project PATH   Read DEVELOPMENT_TEAM from the prior Y3 manual app.
  --reference-scheme NAME    Select a scheme if the reference has multiple teams.
  --team TEAM_ID             Use a known, existing Apple development team instead.
  --bundle-id IDENTIFIER     Default: com.ayato.y3posclient
  --export-options PATH      Reuse an existing local-export ExportOptions.plist.
                            Its team must match; uploading is never performed.
  --output DIRECTORY        New directory for archive, signed IPA, and logs.
                            Default: artifacts/signing/<UTC timestamp>
  --help                    Print this help.

Requires macOS, full Xcode 15+, an installed iOS/Simulator SDK, and the Apple
account/certificates already used for the Y3 manual app. No Apple login or key
import is performed by this script. A simulator build must pass before signing.
The default export is a development IPA for devices in the existing profile.
With an existing export plist, its delivery method is retained as a local export.
Provisioning updates may register the selected bundle ID using the existing account.
USAGE
}

fail() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

require_argument() {
    [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || fail "Missing value for $1."
}

script_directory="$(cd "$(dirname "$0")" && pwd)"
project_directory="$(cd "$script_directory/.." && pwd)"
project_path="$project_directory/Y3Client.xcodeproj"
reference_project=""
reference_scheme=""
team_id=""
bundle_id="com.ayato.y3posclient"
export_options=""
output_directory=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --reference-project)
            require_argument "$@"
            reference_project="$2"
            shift 2
            ;;
        --reference-scheme)
            require_argument "$@"
            reference_scheme="$2"
            shift 2
            ;;
        --team)
            require_argument "$@"
            team_id="$2"
            shift 2
            ;;
        --bundle-id)
            require_argument "$@"
            bundle_id="$2"
            shift 2
            ;;
        --export-options)
            require_argument "$@"
            export_options="$2"
            shift 2
            ;;
        --output)
            require_argument "$@"
            output_directory="$2"
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            fail "Unknown option: $1. Use --help."
            ;;
    esac
done

[[ "$(uname -s)" == Darwin ]] || fail "Signing requires macOS with full Xcode 15+. This host cannot create a signed iPhone IPA."
[[ -d "$project_path" ]] || fail "Y3Client.xcodeproj was not found beside the scripts directory."
[[ -n "$team_id" || -n "$reference_project" ]] || fail "Supply --reference-project for the earlier Y3 manual app, or --team with its real Team ID. No team is assumed."
[[ -z "$team_id" || -z "$reference_project" ]] || fail "Choose either --reference-project or --team."
[[ -z "$reference_scheme" || -n "$reference_project" ]] || fail "--reference-scheme requires --reference-project."
[[ "$bundle_id" =~ ^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$ ]] || fail "Invalid bundle identifier."
if [[ -n "$reference_project" ]]; then
    [[ -d "$reference_project" && "$reference_project" == *.xcodeproj ]] || fail "--reference-project must point to an existing .xcodeproj."
fi
if [[ -n "$export_options" ]]; then
    [[ -f "$export_options" ]] || fail "The supplied ExportOptions.plist does not exist."
fi

command -v xcodebuild >/dev/null 2>&1 || fail "xcodebuild is unavailable; select a full Xcode installation."
xcode_version="$(xcodebuild -version 2>/dev/null)" || fail "Full Xcode is unavailable; check xcode-select."
xcode_major="$(printf '%s\n' "$xcode_version" | sed -n 's/^Xcode \([0-9][0-9]*\).*/\1/p')"
[[ "$xcode_major" =~ ^[0-9]+$ ]] || fail "Could not identify the selected Xcode version."
[[ "$xcode_major" -ge 15 ]] || fail "Xcode 15 or later is required."
xcrun --sdk iphoneos --show-sdk-path >/dev/null 2>&1 || fail "Install the iOS SDK in Xcode first."
xcrun --sdk iphonesimulator --show-sdk-path >/dev/null 2>&1 || fail "Install the iOS Simulator SDK in Xcode first."
python_path="$(xcrun --find python3 2>/dev/null)" || fail "The selected Xcode developer tools must provide python3."
[[ -x "$python_path" ]] || fail "python3 from the selected developer tools is unavailable."

task_temporary_directory="$(mktemp -d "${TMPDIR:-/tmp}/y3client-sign.XXXXXX")"
trap 'rm -rf "$task_temporary_directory"' EXIT

if [[ -n "$reference_project" ]]; then
    reference_arguments=(-project "$reference_project" -configuration Release -sdk iphoneos)
    if [[ -n "$reference_scheme" ]]; then
        reference_arguments+=(-scheme "$reference_scheme")
    else
        reference_arguments+=(-alltargets)
    fi
    # The unfiltered settings can contain environment values: keep them private,
    # extract only the Team ID, and delete the temporary directory on exit.
    if ! xcodebuild "${reference_arguments[@]}" -showBuildSettings -json \
        >"$task_temporary_directory/reference-settings.json" \
        2>"$task_temporary_directory/reference-settings.log"; then
        fail "Could not read the earlier project's signing settings. Open it in this Xcode, or supply its real --team."
    fi
    team_id="$("$python_path" - "$task_temporary_directory/reference-settings.json" <<'PY'
import json
import re
import sys

try:
    with open(sys.argv[1], encoding="utf-8") as source:
        rows = json.load(source)
    settings = [row.get("buildSettings", {}) for row in rows]
    app_settings = [row for row in settings if row.get("WRAPPER_EXTENSION") == "app"]
    teams = {row.get("DEVELOPMENT_TEAM", "").strip() for row in (app_settings or settings)} - {""}
    if len(teams) != 1:
        raise ValueError("The reference must resolve to exactly one development team. Use --reference-scheme or --team.")
    team = teams.pop()
    if not re.fullmatch(r"[A-Z0-9]{10}", team):
        raise ValueError("The reference did not resolve to a real Apple Team ID. Use --team with its existing Team ID.")
    print(team)
except (OSError, ValueError, TypeError, AttributeError) as error:
    print(f"Error: {error}", file=sys.stderr)
    sys.exit(1)
PY
)" || exit 1
fi
[[ "$team_id" =~ ^[A-Z0-9]{10}$ ]] || fail "An Apple Team ID must be 10 uppercase letters/digits."

if [[ "$xcode_major" -ge 16 ]]; then
    default_export_method="debugging"
else
    default_export_method="development"
fi
export_method="$("$python_path" - "$export_options" "$team_id" "$default_export_method" "$task_temporary_directory/ExportOptions.plist" <<'PY'
import plistlib
import sys

source_path, team, default_method, target_path = sys.argv[1:]
try:
    if source_path:
        with open(source_path, "rb") as source:
            options = plistlib.load(source)
        if not isinstance(options, dict):
            raise ValueError("ExportOptions.plist must contain a dictionary.")
        if options.get("destination", "export") != "export":
            raise ValueError("Only destination=export is allowed. Supply a local-export plist; this script never uploads.")
        if options.get("teamID", team) != team:
            raise ValueError("The export plist's teamID differs from the selected signing team.")
        if not isinstance(options.get("method"), str) or not options["method"]:
            raise ValueError("The existing export plist must specify its method.")
        options["teamID"] = team
        options["destination"] = "export"
    else:
        options = {
            "method": default_method,
            "destination": "export",
            "signingStyle": "automatic",
            "teamID": team,
            "stripSwiftSymbols": True,
        }
    with open(target_path, "wb") as target:
        plistlib.dump(options, target)
    print(options["method"])
except (OSError, ValueError, plistlib.InvalidFileException) as error:
    print(f"Error: {error}", file=sys.stderr)
    sys.exit(1)
PY
)" || exit 1

if [[ -z "$output_directory" ]]; then
    output_directory="$project_directory/artifacts/signing/$(date -u '+%Y%m%dT%H%M%SZ')"
fi
[[ ! -e "$output_directory" ]] || fail "The output directory already exists; choose a new directory to avoid replacing earlier artifacts."
mkdir -p "$(dirname "$output_directory")"
mkdir "$output_directory"
output_directory="$(cd "$output_directory" && pwd)"
cp "$task_temporary_directory/ExportOptions.plist" "$output_directory/ExportOptions.plist"
archive_path="$output_directory/Y3Client.xcarchive"

printf 'Using existing team %s for %s.\n' "$team_id" "$bundle_id"
printf 'Checking the iOS Simulator build...\n'
if ! xcodebuild -quiet -project "$project_path" -scheme Y3Client \
    -configuration Debug -sdk iphonesimulator \
    -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath "$task_temporary_directory/SimulatorDerivedData" \
    "PRODUCT_BUNDLE_IDENTIFIER=$bundle_id" CODE_SIGNING_ALLOWED=NO build \
    >"$output_directory/simulator-build.log" 2>&1; then
    fail "Simulator compilation failed. Review $output_directory/simulator-build.log. No archive or IPA was created."
fi

printf 'Archiving with the existing Xcode account and keychain...\n'
if ! xcodebuild -quiet -project "$project_path" -scheme Y3Client \
    -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' \
    -derivedDataPath "$task_temporary_directory/DeviceDerivedData" \
    -archivePath "$archive_path" -allowProvisioningUpdates \
    "DEVELOPMENT_TEAM=$team_id" "PRODUCT_BUNDLE_IDENTIFIER=$bundle_id" \
    CODE_SIGN_STYLE=Automatic CODE_SIGNING_ALLOWED=YES archive \
    >"$output_directory/archive.log" 2>&1; then
    fail "Archive/signing failed. Review $output_directory/archive.log. The existing account must have this team's signing access. No exported IPA was created."
fi

printf 'Exporting a signed IPA (%s)...\n' "$export_method"
if ! xcodebuild -quiet -exportArchive -archivePath "$archive_path" \
    -exportPath "$output_directory/export" \
    -exportOptionsPlist "$output_directory/ExportOptions.plist" \
    -allowProvisioningUpdates >"$output_directory/export.log" 2>&1; then
    fail "Signed IPA export failed. Review $output_directory/export.log. An archive alone is not a delivered IPA."
fi

# Keep unmatched globs as one non-existent path. This also avoids the empty-array
# nounset differences in the Bash 3.2 shipped with macOS.
ipa_paths=("$output_directory/export/"*.ipa)
[[ ${#ipa_paths[@]} -eq 1 && -f "${ipa_paths[0]}" ]] || fail "Export did not produce exactly one IPA; no success is claimed."
ipa_path="${ipa_paths[0]}"
/usr/bin/ditto -x -k "$ipa_path" "$task_temporary_directory/ExportedIPA"
app_paths=("$task_temporary_directory/ExportedIPA/Payload/"*.app)
[[ ${#app_paths[@]} -eq 1 && -d "${app_paths[0]}" ]] || fail "The exported IPA does not contain exactly one app."
app_path="${app_paths[0]}"
if ! /usr/bin/codesign --verify --deep --strict "$app_path" \
    >"$output_directory/signature-verification.log" 2>&1; then
    fail "The exported IPA failed code-signature verification. Review $output_directory/signature-verification.log."
fi
if ! /usr/bin/codesign -d --verbose=4 "$app_path" 2>"$task_temporary_directory/signature-details.txt"; then
    fail "Could not read the exported IPA's signing identity; no success is claimed."
fi
signed_team="$(sed -n 's/^TeamIdentifier=//p' "$task_temporary_directory/signature-details.txt")"
[[ "$signed_team" == "$team_id" ]] || fail "The IPA's signature does not belong to the selected team."

"$python_path" - "$app_path/Info.plist" "$team_id" "$bundle_id" "$export_method" "$ipa_path" "$archive_path" "$output_directory/BuildMetadata.json" "$xcode_version" <<'PY'
import datetime
import hashlib
import json
import pathlib
import plistlib
import sys

info_path, team, expected_bundle, method, ipa_path, archive_path, output_path, xcode_version = sys.argv[1:]
with open(info_path, "rb") as source:
    info = plistlib.load(source)
if info.get("CFBundleIdentifier") != expected_bundle:
    print("Error: The exported bundle identifier differs from the selected identifier.", file=sys.stderr)
    sys.exit(1)
digest = hashlib.sha256()
with open(ipa_path, "rb") as source:
    for block in iter(lambda: source.read(1024 * 1024), b""):
        digest.update(block)
metadata = {
    "createdAtUTC": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "developmentTeam": team,
    "bundleIdentifier": info["CFBundleIdentifier"],
    "version": info.get("CFBundleShortVersionString"),
    "build": info.get("CFBundleVersion"),
    "exportMethod": method,
    "xcodeVersion": xcode_version,
    "ipa": "export/" + pathlib.Path(ipa_path).name,
    "ipaSHA256": digest.hexdigest(),
    "archive": pathlib.Path(archive_path).name,
    "simulatorBuildPassed": True,
    "exportedSignatureVerified": True,
}
with open(output_path, "w", encoding="utf-8") as target:
    json.dump(metadata, target, ensure_ascii=False, indent=2)
    target.write("\n")
PY

printf 'Signed IPA verified: %s\n' "$ipa_path"
printf 'Build metadata: %s/BuildMetadata.json\n' "$output_directory"
printf 'For development exports, install only on devices allowed by the signing profile.\n'
