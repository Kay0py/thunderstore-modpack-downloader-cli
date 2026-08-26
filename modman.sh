#!/usr/bin/env bash
set -euo pipefail

# ==========================================
# ARGUMENT PARSING
# ==========================================

AUTO_YES=false
KEEP_TEMP=false
VERBOSE=false
MAKE_ZIP=false

POSITIONAL=()
while [[ $# -gt 0 ]]; do
    case $1 in
        -y|--yes) AUTO_YES=true; shift ;;
        -k|--keep-temp) KEEP_TEMP=true; shift ;;
        -v|--verbose) VERBOSE=true; shift ;;
        -z|--zip) MAKE_ZIP=true; shift ;;
        -h|--help)
            cat << 'HELP'
Usage: unifiedscript.sh [OPTIONS] <PROFILE_CODE|MODPACK_URL|AUTHOR-MODNAME-VERSION>

Options:
  -y, --yes          Skip confirmation prompts
  -k, --keep-temp    Preserve temporary files on exit for debugging
  -v, --verbose      Enable verbose output
  -z, --zip          Create a final archive of the build
  -h, --help         Show this help message
HELP
            exit 0
            ;;
        --) shift; POSITIONAL+=("$@"); break ;;
        -*)
            echo "Error: Unknown option $1" >&2
            echo "Use -h or --help for usage information." >&2
            exit 1
            ;;
        *) POSITIONAL+=("$1"); shift ;;
    esac
done

set -- "${POSITIONAL[@]}"

if [ -z "${1:-}" ]; then
    echo "Error: Missing input parameter." >&2
    echo "Usage: $0 [OPTIONS] <R2MODMAN_PROFILE_CODE|THUNDERSTORE_MODPACK_URL|AUTHOR-MODNAME-VERSION>" >&2
    exit 1
fi

INPUT="$1"

# ==========================================
# DEPENDENCY CHECKS
# ==========================================

for cmd in python3 curl unzip base64; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Error: Missing required tool: $cmd" >&2
        exit 1
    fi
done

# ==========================================
# ARCHIVER DETECTION
# ==========================================

detect_archiver() {
    if command -v zip >/dev/null 2>&1; then
        echo "zip"
    elif command -v 7z >/dev/null 2>&1; then
        echo "7z"
    elif command -v tar >/dev/null 2>&1; then
        echo "tar"
    else
        echo "none"
    fi
}

# ==========================================
# INITIALIZATION & SAFETY
# ==========================================

WORK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export STAGING_DIR="$WORK_DIR/staging"
BUILD_DIR="$WORK_DIR/build"
LOCKFILE="$WORK_DIR/.modpack_builder.lock"

exec 200>"$LOCKFILE"
if ! flock -n 200; then
    echo "Error: Another instance is already running." >&2
    exit 1
fi

cleanup() {
    if [ "${KEEP_TEMP:-false}" = true ]; then
        echo "Keeping temporary files."
        return
    fi
    rm -rf "$STAGING_DIR" \
           "$WORK_DIR/profile_manifest" \
           "$WORK_DIR/export.r2z" \
           "$WORK_DIR/raw_payload.txt"
}

trap cleanup EXIT INT TERM

if [ -d "$STAGING_DIR" ] || [ -d "$BUILD_DIR" ] || \
   [ -d "$WORK_DIR/profile_manifest" ] || \
   [ -f "$WORK_DIR/export.r2z" ] || \
   [ -f "$WORK_DIR/raw_payload.txt" ] || \
   [ -f "$WORK_DIR/build.zip" ] || \
   [ -f "$WORK_DIR/build.tar.gz" ] || \
   [ -f "$WORK_DIR/build.7z" ]; then
   
    if [ "$AUTO_YES" = false ]; then
        read -p "Existing build artifacts found. Remove them? [y/N]: " confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            echo "Aborting."
            exit 0
        fi
    fi
    rm -rf "$STAGING_DIR" "$BUILD_DIR" "$WORK_DIR/profile_manifest" "$WORK_DIR/export.r2z" "$WORK_DIR/raw_payload.txt"
    rm -f "$WORK_DIR/build.zip" "$WORK_DIR/build.tar.gz" "$WORK_DIR/build.7z"
fi

if [[ "$INPUT" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
    export RUN_MODE="profile"
    export PROFILE_CODE="$INPUT"
    export MANIFEST_FILE="$WORK_DIR/profile_manifest/export.r2x"
    echo "Mode: r2modman Profile Export"
else
    export RUN_MODE="modpack"
    export MODPACK_INPUT="$INPUT"
    echo "Mode: Thunderstore Modpack"
fi

# ==========================================
# FETCH PROFILE PAYLOAD
# ==========================================

if [ "$RUN_MODE" = "profile" ]; then
    echo "Fetching profile payload..."
    if ! curl -sSLf "https://thunderstore.io/api/experimental/legacyprofile/get/${PROFILE_CODE}/" -o "$WORK_DIR/raw_payload.txt"; then
        echo "Error: Failed to fetch profile payload." >&2
        exit 1
    fi

    echo "Decoding payload..."
    if ! sed '/^#/d' "$WORK_DIR/raw_payload.txt" | base64 -d > "$WORK_DIR/export.r2z"; then
        echo "Error: Failed to decode profile payload." >&2
        exit 1
    fi

    echo "Extracting manifest..."
    if ! unzip -q -o "$WORK_DIR/export.r2z" -d "$WORK_DIR/profile_manifest"; then
        echo "Error: Failed to extract profile archive." >&2
        exit 1
    fi
fi

# ==========================================
# PYTHON EXTRACTION ENGINE
# ==========================================

echo "Downloading mods..."

export AUTO_YES KEEP_TEMP VERBOSE MAKE_ZIP

python3 - << 'EOF'
import os
import re
import shutil
import urllib.request
import urllib.error
import zipfile
import time
import json
import sys
from concurrent.futures import ThreadPoolExecutor, as_completed
from threading import Lock

run_mode = os.environ["RUN_MODE"]
staging_dir = os.environ["STAGING_DIR"]
verbose = os.environ.get("VERBOSE", "false").lower() == "true"

bepinex_dir = os.path.join(staging_dir, "BepInEx")
plugins_dir = os.path.join(bepinex_dir, "plugins")
patchers_dir = os.path.join(bepinex_dir, "patchers")
core_dir = os.path.join(bepinex_dir, "core")
config_dir = os.path.join(bepinex_dir, "config")
temp_dir = os.path.join(staging_dir, "_temp")

if os.path.exists(staging_dir):
    shutil.rmtree(staging_dir)

os.makedirs(plugins_dir, exist_ok=True)
os.makedirs(patchers_dir, exist_ok=True)
os.makedirs(core_dir, exist_ok=True)
os.makedirs(config_dir, exist_ok=True)
os.makedirs(temp_dir, exist_ok=True)

downloaded_mods = set()
download_lock = Lock()

THUNDERSTORE_META = {
    "manifest.json", "icon.png", "readme.md", "readme",
    "changelog.md", "changelog.txt", "changelog",
    "license", "license.md", "license.txt"
}

def vprint(msg):
    if verbose:
        print(msg)

def load_json_robust(filepath):
    with open(filepath, "rb") as f:
        raw_data = f.read()
    for enc in ["utf-8-sig", "utf-16"]:
        try:
            return json.loads(raw_data.decode(enc))
        except (UnicodeDecodeError, json.JSONDecodeError):
            continue
    print(f"Warning: Unrecognized encoding in {filepath}. Skipping dependencies.")
    return {}

def find_dir(base, name):
    if not os.path.isdir(base):
        return None
    for d in os.listdir(base):
        if d.lower() == name.lower() and os.path.isdir(os.path.join(base, d)):
            return os.path.join(base, d)
    return None

def copy_preserve(src, dst):
    os.makedirs(dst, exist_ok=True)
    for item in os.listdir(src):
        s = os.path.join(src, item)
        d = os.path.join(dst, item)
        if os.path.isdir(s):
            shutil.copytree(s, d, dirs_exist_ok=True)
        else:
            shutil.copy2(s, d)

def parse_mod_string(mod_string):
    parts = mod_string.split("-")
    if len(parts) >= 3:
        author = parts[0]
        ver = parts[-1]
        pkg = "-".join(parts[1:-1])
        return author, pkg, ver
    return None, None, None

def is_base_loader_root(path):
    return (os.path.isdir(os.path.join(path, "BepInEx")) or
            os.path.isfile(os.path.join(path, "doorstop_config.ini")) or
            os.path.isfile(os.path.join(path, "winhttp.dll")))

def process_extracted_mod(temp_extract, full_name):
    items = os.listdir(temp_extract)

    if "BepInExPack" in items or "BepInExPack" in full_name:
        pack_root = temp_extract
        
        if not is_base_loader_root(temp_extract):
            for item in items:
                item_path = os.path.join(temp_extract, item)
                if os.path.isdir(item_path) and is_base_loader_root(item_path):
                    pack_root = item_path
                    vprint(f"Detected wrapper folder: {item}")
                    break
        
        for item in os.listdir(pack_root):
            src = os.path.join(pack_root, item)
            if item == "BepInEx":
                shutil.copytree(src, bepinex_dir, dirs_exist_ok=True)
            elif os.path.isdir(src) and item.lower() in ("plugins", "patchers", "core", "config"):
                dst = os.path.join(bepinex_dir, item)
                shutil.copytree(src, dst, dirs_exist_ok=True)
            elif os.path.isdir(src):
                dst = os.path.join(staging_dir, item)
                shutil.copytree(src, dst, dirs_exist_ok=True)
            else:
                if item.lower() not in THUNDERSTORE_META:
                    shutil.copy2(src, staging_dir)
                else:
                    vprint(f"Skipping metadata file: {item}")
        shutil.rmtree(temp_extract)
        return

    bep_root = find_dir(temp_extract, "bepinex")
    if not bep_root:
        bep_root = temp_extract

    src_plugins = find_dir(bep_root, "plugins")
    src_patchers = find_dir(bep_root, "patchers")
    src_core = find_dir(bep_root, "core")
    src_config = find_dir(bep_root, "config")
    
    if not src_config:
        src_config = find_dir(temp_extract, "config")

    plugin_target = os.path.join(plugins_dir, full_name)
    os.makedirs(plugin_target, exist_ok=True)

    if src_config:
        copy_preserve(src_config, config_dir)

    if src_plugins:
        copy_preserve(src_plugins, plugin_target)
    if src_patchers:
        target_patcher = os.path.join(patchers_dir, full_name)
        copy_preserve(src_patchers, target_patcher)
    if src_core:
        target_core = os.path.join(core_dir, full_name)
        copy_preserve(src_core, target_core)

    handled_dirs = [os.path.abspath(d) for d in [src_plugins, src_patchers, src_core, src_config] if d is not None]
    
    for dirpath, dirnames, filenames in os.walk(temp_extract):
        abs_dirpath = os.path.abspath(dirpath)
        is_handled = False
        for h_dir in handled_dirs:
            if abs_dirpath == h_dir or abs_dirpath.startswith(h_dir + os.sep):
                is_handled = True
                break
        
        if is_handled:
            continue
        
        for f in filenames:
            s_file = os.path.join(dirpath, f)
            d_file = os.path.join(plugin_target, f)
            if os.path.isdir(s_file):
                continue
            if not os.path.exists(d_file):
                shutil.copy2(s_file, d_file)

    shutil.rmtree(temp_extract)

def download_mod(author, pkg, ver_str):
    full_name = f"{author}-{pkg}"
    mod_id = f"{full_name}-{ver_str}"
    
    with download_lock:
        if mod_id in downloaded_mods:
            return []
        downloaded_mods.add(mod_id)

    download_url = f"https://thunderstore.io/package/download/{author}/{pkg}/{ver_str}/"
    zip_path = os.path.join(temp_dir, f"{mod_id}.zip")
    temp_extract = os.path.join(temp_dir, mod_id)

    print(f"Downloading: {mod_id}")
    
    download_success = False
    max_retries = 5
    
    for attempt in range(1, max_retries + 1):
        try:
            req = urllib.request.Request(
                download_url, headers={"User-Agent": "Mozilla/5.0 (X11; Linux x86_64)"}
            )
            with urllib.request.urlopen(req, timeout=15) as response, open(zip_path, "wb") as out_file:
                out_file.write(response.read())
            download_success = True
            break
        except urllib.error.HTTPError as e:
            print(f"  HTTP error ({attempt}/{max_retries}): {e.code}")
            if e.code == 404:
                break
            if attempt < max_retries:
                time.sleep(attempt * 2)
        except Exception as e:
            print(f"  Network error ({attempt}/{max_retries}): {e}")
            if attempt < max_retries:
                time.sleep(attempt * 2)

    if not download_success:
        raise RuntimeError(f"Failed to download: {mod_id}")

    with zipfile.ZipFile(zip_path, "r") as zip_ref:
        zip_ref.extractall(temp_extract)
    os.remove(zip_path)

    manifest_file = os.path.join(temp_extract, "manifest.json")
    deps = []
    if os.path.exists(manifest_file):
        manifest = load_json_robust(manifest_file)
        deps = manifest.get("dependencies", [])
        if deps:
            vprint(f"Found {len(deps)} dependencies for {mod_id}")

    process_extracted_mod(temp_extract, full_name)
    return deps

# ----------------------------------------
# PIPELINE EXECUTION
# ----------------------------------------

if run_mode == "profile":
    manifest_path = os.environ["MANIFEST_FILE"]
    if not os.path.exists(manifest_path):
        print("Error: Profile manifest not found.", file=sys.stderr)
        sys.exit(1)
        
    with open(manifest_path, "r", encoding="utf-8-sig") as f:
        content = f.read()

    mod_blocks = content.split("- name:")
    tasks = []
    
    for block in mod_blocks[1:]:
        lines = block.strip().split("\n")
        if not lines:
            continue
        full_name = lines[0].strip()

        if re.search(r'^\s*enabled:\s*false\s*$', block, re.MULTILINE):
            vprint(f"Skipping disabled mod: {full_name}")
            continue

        major_match = re.search(r"major:\s*(\d+)", block)
        minor_match = re.search(r"minor:\s*(\d+)", block)
        patch_match = re.search(r"patch:\s*(\d+)", block)
        
        if not all([major_match, minor_match, patch_match]):
            print(f"Warning: Skipping malformed block: {full_name}")
            continue
            
        major = major_match.group(1)
        minor = minor_match.group(1)
        patch = patch_match.group(1)
        ver_str = f"{major}.{minor}.{patch}"

        if "-" not in full_name:
            print(f"Warning: Skipping invalid mod name: {full_name}")
            continue
            
        author, pkg = full_name.split("-", 1)
        tasks.append((author, pkg, ver_str))

    with ThreadPoolExecutor(max_workers=4) as executor:
        futures = {executor.submit(download_mod, a, p, v): (a, p, v) for a, p, v in tasks}
        for future in as_completed(futures):
            a, p, v = futures[future]
            try:
                future.result()
            except Exception as e:
                print(f"Error: Failed to process {a}-{p}-{v}: {e}", file=sys.stderr)
                sys.exit(1)

elif run_mode == "modpack":
    modpack_input = os.environ["MODPACK_INPUT"]
    
    author = None
    pkg = None
    ver = None

    if modpack_input.startswith("http"):
        clean_url = modpack_input.rstrip("/")
        match = re.search(r"/(?:package|p)/([^/]+)/([^/]+)(?:/([^/]+))?$", clean_url)
        if match:
            author = match.group(1)
            pkg = match.group(2)
            ver = match.group(3) if match.lastindex >= 3 else None
    else:
        author, pkg, ver = parse_mod_string(modpack_input)
        if not author:
            parts = modpack_input.split("-")
            if len(parts) == 2:
                author, pkg = parts
            else:
                raise ValueError("Invalid format. Use URL or Author-Mod-Version")

    if not author or not pkg:
        raise ValueError(f"Could not parse identifier: {modpack_input}")
    
    if re.search(r"[<>'\"\\]", author + pkg):
        raise ValueError("Invalid characters in package identifier")

    if not ver:
        print(f"Fetching latest version for {author}-{pkg}...")
        
        req = urllib.request.Request(
            f"https://thunderstore.io/api/experimental/package/{author}/{pkg}/",
            headers={"User-Agent": "Mozilla/5.0"}
        )
        try:
            with urllib.request.urlopen(req, timeout=15) as res:
                if res.status != 200:
                    raise RuntimeError(f"HTTP {res.status}")
                data = json.loads(res.read().decode('utf-8-sig'))
                ver = data["latest"]["version_number"]
                print(f"Latest version: {ver}")
        except (urllib.error.HTTPError, urllib.error.URLError) as e:
            raise RuntimeError(f"Failed to fetch metadata: {e}")

    queue = [(author, pkg, ver)]
    seen = set()
    
    while queue:
        batch = []
        for item in queue:
            mod_id = f"{item[0]}-{item[1]}-{item[2]}"
            if mod_id not in seen:
                seen.add(mod_id)
                batch.append(item)
        queue = []
        if not batch:
            break
        
        vprint(f"Processing batch of {len(batch)} mod(s)...")
        with ThreadPoolExecutor(max_workers=4) as executor:
            futures = {executor.submit(download_mod, a, p, v): (a, p, v) for a, p, v in batch}
            for future in as_completed(futures):
                a, p, v = futures[future]
                try:
                    deps = future.result()
                    for dep in deps:
                        d_author, d_pkg, d_ver = parse_mod_string(dep)
                        if d_author:
                            queue.append((d_author, d_pkg, d_ver))
                except Exception as e:
                    print(f"Error: Failed to process {a}-{p}-{v}: {e}", file=sys.stderr)
                    sys.exit(1)

if os.path.exists(temp_dir):
    shutil.rmtree(temp_dir)
EOF

echo -e "\033[1;32mDownload complete.\033[0m"

# ==========================================
# FINAL ASSEMBLY
# ==========================================

echo "Assembling build..."
mkdir -p "$BUILD_DIR"
cp -r "$STAGING_DIR/"* "$BUILD_DIR/"

# Profile mode: overlay custom configs from the exported profile.
# The profile_manifest may contain a BepInEx/ tree with per-profile
# plugin configs and overrides that must take precedence over defaults.
if [ "$RUN_MODE" = "profile" ]; then
    if [ -d "$WORK_DIR/profile_manifest/BepInEx" ]; then
        echo "Applying profile BepInEx overrides..."
        mkdir -p "$BUILD_DIR/BepInEx"
        (
            shopt -s dotglob
            cp -rf "$WORK_DIR/profile_manifest/BepInEx/"* "$BUILD_DIR/BepInEx/"
        )
    fi

    if [ -d "$WORK_DIR/profile_manifest/config" ]; then
        echo "Applying profile configs..."
        mkdir -p "$BUILD_DIR/BepInEx/config"
        (
            shopt -s dotglob
            cp -rf "$WORK_DIR/profile_manifest/config/"* "$BUILD_DIR/BepInEx/config/"
        )
    fi
fi

if [ "$MAKE_ZIP" = true ]; then
    ARCHIVER=$(detect_archiver)
    if [ "$ARCHIVER" = "none" ]; then
        echo "Warning: No archiver found (tried: zip, 7z, tar). Build directory is intact." >&2
    else
        echo "Creating archive..."
        case "$ARCHIVER" in
            zip)
                if (cd "$WORK_DIR" && zip -r "build.zip" "build/"); then
                    echo "Archive created: $WORK_DIR/build.zip"
                else
                    echo "Warning: Archive creation failed." >&2
                fi
                ;;
            7z)
                if (cd "$WORK_DIR" && 7z a "build.zip" "build/" >/dev/null 2>&1); then
                    echo "Archive created: $WORK_DIR/build.zip"
                else
                    echo "Warning: Archive creation failed." >&2
                fi
                ;;
            tar)
                if (cd "$WORK_DIR" && tar -czf "build.tar.gz" "build/"); then
                    echo "Archive created: $WORK_DIR/build.tar.gz"
                else
                    echo "Warning: Archive creation failed." >&2
                fi
                ;;
        esac
    fi
fi

echo -e "\033[1;32mBuild ready: $BUILD_DIR\033[0m"
