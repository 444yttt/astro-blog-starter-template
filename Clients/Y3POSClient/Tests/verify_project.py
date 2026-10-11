"""Validate project structure and Swift grammar without claiming an iOS build."""

from pathlib import Path
import json
import plistlib
import struct
import sys
import xml.etree.ElementTree as ET

try:
    from openstep_parser import OpenStepDecoder
    from tree_sitter import Language, Parser
    import tree_sitter_swift
except ImportError as error:
    raise SystemExit(
        f"Missing verification dependency: {error}. "
        "Install with: python -m pip install -r Tests/requirements.txt"
    ) from error


ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "Y3Client"
PROJECT = ROOT / "Y3Client.xcodeproj"


def require(condition, message):
    if not condition:
        raise ValueError(message)


def check_project():
    with (PROJECT / "project.pbxproj").open() as source:
        project = OpenStepDecoder.ParseFromFile(source)
    objects = project["objects"]
    require(project["rootObject"] in objects, "Missing project root")
    single_refs = (
        "fileRef", "buildConfigurationList", "productReference", "mainGroup",
        "productRefGroup",
    )
    array_refs = (
        "children", "files", "buildPhases", "dependencies", "buildConfigurations",
        "targets",
    )
    for identifier, item in objects.items():
        require(
            len(identifier) == 24 and all(c in "0123456789ABCDEF" for c in identifier),
            f"Invalid project object identifier: {identifier}",
        )
        for key in single_refs:
            if key in item:
                require(item[key] in objects, f"Broken {identifier}.{key}")
        for key in array_refs:
            for ref in item.get(key, []):
                require(ref in objects, f"Broken {identifier}.{key}: {ref}")

    file_paths = {}

    def walk_group(identifier, parent):
        item = objects[identifier]
        if item["isa"] == "PBXGroup":
            folder = parent / item.get("path", "")
            for child in item.get("children", []):
                walk_group(child, folder)
        elif item["isa"] == "PBXFileReference":
            if item.get("sourceTree") == "BUILT_PRODUCTS_DIR":
                return
            require(item.get("sourceTree") == "<group>", f"Unexpected file source: {item}")
            path = parent / item["path"]
            require(path.exists(), f"Missing referenced file: {path.relative_to(ROOT)}")
            file_paths[identifier] = path

    walk_group(objects[project["rootObject"]]["mainGroup"], ROOT)
    targets = [item for item in objects.values() if item["isa"] == "PBXNativeTarget"]
    require(len(targets) == 1 and targets[0]["name"] == "Y3Client", "Unexpected app target")
    target = targets[0]
    sources = []
    resources = []
    for phase_id in target["buildPhases"]:
        phase = objects[phase_id]
        paths = [file_paths[objects[ref]["fileRef"]] for ref in phase.get("files", [])]
        if phase["isa"] == "PBXSourcesBuildPhase":
            sources.extend(paths)
        elif phase["isa"] == "PBXResourcesBuildPhase":
            resources.extend(paths)
    require(len(sources) == len(set(sources)), "Duplicate Swift build source")
    require(set(sources) == set(APP.glob("*.swift")), "Swift source/build phase mismatch")
    require(APP / "Assets.xcassets" in resources, "Assets missing from resources")
    require(APP / "Info.plist" not in resources, "Info.plist must not be a copied resource")
    configurations = objects[target["buildConfigurationList"]]["buildConfigurations"]
    for config_id in configurations:
        settings = objects[config_id]["buildSettings"]
        require(settings["TARGETED_DEVICE_FAMILY"] == "1", "Target must be iPhone")
        require(settings["IPHONEOS_DEPLOYMENT_TARGET"] == "17.0", "Unexpected minimum iOS")
        require(settings["CODE_SIGN_STYLE"] == "Automatic", "Automatic signing missing")
        require(settings["DEVELOPMENT_TEAM"] == "", "Signing Team should be configured by user")
        require((ROOT / settings["INFOPLIST_FILE"]).is_file(), "Info.plist build path invalid")
    scheme = ET.parse(PROJECT / "xcshareddata/xcschemes/Y3Client.xcscheme")
    for reference in scheme.findall(".//BuildableReference"):
        require(reference.attrib["BlueprintIdentifier"] in objects, "Scheme target missing")
        require(reference.attrib["ReferencedContainer"] == "container:Y3Client.xcodeproj", "Scheme container mismatch")
    ET.parse(PROJECT / "project.xcworkspace/contents.xcworkspacedata")
    return {"objects": len(objects), "referenced_files": len(file_paths), "swift_files": len(sources)}


def check_metadata():
    info = plistlib.loads((APP / "Info.plist").read_bytes())
    require("NSAppTransportSecurity" not in info, "Unexpected ATS exceptions")
    require(info["CFBundleIdentifier"] == "$(PRODUCT_BUNDLE_IDENTIFIER)", "Bundle identifier substitution missing")
    require(len(info["UISupportedInterfaceOrientations"]) == 3, "Missing phone orientations")
    assets = APP / "Assets.xcassets"
    json.loads((assets / "Contents.json").read_text())
    iconset = assets / "AppIcon.appiconset"
    entries = json.loads((iconset / "Contents.json").read_text())["images"]
    for entry in entries:
        image = (iconset / entry["filename"]).read_bytes()
        require(image[:8] == b"\x89PNG\r\n\x1a\n", f"Invalid PNG: {entry['filename']}")
        require(image[12:16] == b"IHDR", f"Invalid PNG header: {entry['filename']}")
        width, height, depth, color_type = struct.unpack(">IIBB", image[16:26])
        points = int(entry["size"].split("x")[0])
        scale = int(entry["scale"].removesuffix("x"))
        require((width, height) == (points * scale, points * scale), f"Icon dimensions: {entry['filename']}")
        require(depth == 8 and color_type == 2, f"Icon must be opaque RGB: {entry['filename']}")
    require(any(item["size"] == "1024x1024" for item in entries), "Missing 1024 App Store icon")
    return {"app_icons": len(entries), "ats_exceptions": False}


def check_swift_grammar():
    parser = Parser(Language(tree_sitter_swift.language()))
    results = {}
    for path in sorted(APP.glob("*.swift")):
        source = path.read_bytes()
        tree = parser.parse(source)
        errors = []

        def visit(node):
            if node.is_error or node.is_missing:
                errors.append({
                    "kind": node.type,
                    "line": node.start_point.row + 1,
                    "column": node.start_point.column + 1,
                    "text": source[node.start_byte:node.end_byte][:120].decode(errors="replace"),
                })
            for child in node.children:
                visit(child)

        visit(tree.root_node)
        require(not errors, f"Swift syntax errors in {path.name}: {errors}")
        results[path.name] = "parsed"
    return results


def main():
    result = {
        "status": "passed",
        "project": check_project(),
        "metadata": check_metadata(),
        "swift_grammar": check_swift_grammar(),
        "limits": "Structural and grammar checks only; no Apple SDK type checking, Xcode build, signing, or iPhone execution.",
    }
    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, OSError, SyntaxError) as error:
        print(json.dumps({"status": "failed", "error": str(error)}, ensure_ascii=False), file=sys.stderr)
        raise SystemExit(1) from error
