#!/bin/bash
# Build and package the Jellyfin 2FA plugin (fat package by default)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR/src/Jellyfin.Plugin.TwoFactorAuth"
MODE="${1:-fat}"
INSTALL_FLAG="${2:-}"
OUTPUT_DIR="$SCRIPT_DIR/dist/TwoFactorAuth"

# --- multi-ABI: which Jellyfin to build against ------------------------------
# Default 10.11.9 (net9). Pass JELLYFIN_VERSION=12.0.0 (with a .NET 10 SDK on
# PATH, or via DOTNET=/path/to/dotnet) for the Jellyfin 12 build; the csproj
# maps 12.x -> net10 + a JELLYFIN12 symbol. On net10 the BCL ships
# System.Formats.Cbor, so it is not bundled and drops out of the meta
# assemblies list (a smoke test on real Jellyfin 12 caught this: listing a
# missing assembly makes Jellyfin mark the plugin "Malfunctioned").
JELLYFIN_VERSION="${JELLYFIN_VERSION:-10.11.9}"
DOTNET="${DOTNET:-dotnet}"
IS_JF12=0
case "$JELLYFIN_VERSION" in 12.*) IS_JF12=1 ;; esac

PROJECT_VERSION="$(grep -oPm1 '(?<=<Version>)[^<]+' "$PROJECT_DIR/Jellyfin.Plugin.TwoFactorAuth.csproj")"
META_VERSION="$(grep -oPm1 '(?<=\"version\": \")[^\"]+' "$PROJECT_DIR/meta.json")"
if [ "$PROJECT_VERSION" != "$META_VERSION" ]; then
    echo "Version mismatch: project=$PROJECT_VERSION meta.json=$META_VERSION" >&2
    exit 1
fi
for property in name description guid version targetAbi owner overview category status autoUpdate imagePath assemblies; do
    if ! grep -q "\"$property\"[[:space:]]*:" "$PROJECT_DIR/meta.json"; then
        echo "meta.json must contain Jellyfin's exact case-sensitive '$property' property" >&2
        exit 1
    fi
done
if ! grep -q '"imagePath"[[:space:]]*:[[:space:]]*"logo.png"' "$PROJECT_DIR/meta.json"; then
    echo "meta.json imagePath must be exactly 'logo.png'" >&2
    exit 1
fi
if [ ! -f "$SCRIPT_DIR/assets/logo.png" ]; then
    echo "Package image is missing: assets/logo.png" >&2
    exit 1
fi

if [ "$MODE" = "--install" ]; then
    MODE="fat"
    INSTALL_FLAG="--install"
fi

if [ "$MODE" = "fat" ]; then
    RIDS=(linux-x64 linux-arm64 linux-musl-x64)
else
    RIDS=("$MODE")
    OUTPUT_DIR="$SCRIPT_DIR/dist/TwoFactorAuth-$MODE"
fi

rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"

# Build managed assemblies once without RID (architecture-agnostic).
# Jellyfin.Controller / Jellyfin.Model are pinned to exact 10.11.8 in the
# csproj (not 10.11.*), so we don't need locked-mode restore here — the
# wildcard-rolls-forward problem that bit v2.4.3 can't recur.
BASE_PUBLISH_DIR="$SCRIPT_DIR/dist/publish-base"
rm -rf "$BASE_PUBLISH_DIR"
echo "Building managed plugin (Release, no RID, Jellyfin $JELLYFIN_VERSION)..."
"$DOTNET" publish "$PROJECT_DIR" -c Release -p:JellyfinVersion="$JELLYFIN_VERSION" --self-contained false -o "$BASE_PUBLISH_DIR" --nologo

for file in \
    Jellyfin.Plugin.TwoFactorAuth.dll \
    Otp.NET.dll \
    QRCoder.dll \
    Fido2.dll \
    Fido2.Models.dll \
    NSec.Cryptography.dll \
    System.Formats.Cbor.dll \
    Microsoft.Bcl.Memory.dll \
    MaxMind.Db.dll \
    QuestPDF.dll \
    IdentityModel.OidcClient.dll \
    IdentityModel.dll \
    Microsoft.IdentityModel.Abstractions.dll \
    Microsoft.IdentityModel.JsonWebTokens.dll \
    Microsoft.IdentityModel.Logging.dll \
    Microsoft.IdentityModel.Tokens.dll \
    System.IdentityModel.Tokens.Jwt.dll \
    MailKit.dll \
    MimeKit.dll \
    BouncyCastle.Cryptography.dll \
; do
    # net10 (Jellyfin 12) ships System.Formats.Cbor in the BCL, so it is not
    # published as a bundled assembly and is dropped from the J12 meta below.
    if [ "$IS_JF12" = "1" ] && [ "$file" = "System.Formats.Cbor.dll" ]; then
        continue
    fi
    if [ ! -f "$BASE_PUBLISH_DIR/$file" ]; then
        echo "Required package assembly is missing: $file" >&2
        exit 1
    fi
    if ! grep -q "\"$file\"" "$PROJECT_DIR/meta.json"; then
        echo "meta.json assemblies is missing required entry: $file" >&2
        exit 1
    fi
    cp "$BASE_PUBLISH_DIR/$file" "$OUTPUT_DIR/"
done

for RID in "${RIDS[@]}"; do
    PUBLISH_DIR="$SCRIPT_DIR/dist/publish-$RID"
    rm -rf "$PUBLISH_DIR"
    echo "Building plugin (Release, RID=$RID, Jellyfin $JELLYFIN_VERSION)..."
    "$DOTNET" publish "$PROJECT_DIR" -c Release -p:JellyfinVersion="$JELLYFIN_VERSION" -r "$RID" --self-contained false -o "$PUBLISH_DIR" --nologo

    NATIVE_DIR="$PUBLISH_DIR/runtimes/$RID/native"
    TARGET_NATIVE_DIR="$OUTPUT_DIR/runtimes/$RID/native"
    mkdir -p "$TARGET_NATIVE_DIR"

    # Some packages place native libs under runtimes/<rid>/native, others at publish root.
    if [ -d "$NATIVE_DIR" ]; then
        cp "$NATIVE_DIR"/* "$TARGET_NATIVE_DIR/" 2>/dev/null || true
    fi
    cp "$PUBLISH_DIR"/*.so "$TARGET_NATIVE_DIR/" 2>/dev/null || true

    # Jellyfin/.NET in this plugin scenario probes native libs from plugin root.
    # Keep a copy at root to avoid QuestPDF load failures in containers.
    cp "$PUBLISH_DIR"/*.so "$OUTPUT_DIR/" 2>/dev/null || true
done

# Copy meta.json (patch it for the Jellyfin 12 build: raise targetAbi and drop
# the BCL-provided assembly that net10 does not bundle).
cp "$PROJECT_DIR/meta.json" "$OUTPUT_DIR/"
if [ "$IS_JF12" = "1" ]; then
    sed -i 's/"targetAbi": "10.11.0.0"/"targetAbi": "12.0.0.0"/' "$OUTPUT_DIR/meta.json"
    sed -i '/"System.Formats.Cbor.dll",/d' "$OUTPUT_DIR/meta.json"
    echo "Patched meta.json for Jellyfin 12 (targetAbi 12.0.0.0, no System.Formats.Cbor.dll)."
fi
# imageUrl only helps catalog installs. Jellyfin serves installed plugin
# artwork from Manifest.ImagePath, so include it for manual packages too (#131).
cp "$SCRIPT_DIR/assets/logo.png" "$OUTPUT_DIR/logo.png"

echo ""
echo "Plugin built to: $OUTPUT_DIR"
ls -la "$OUTPUT_DIR"

# Install if --install flag passed
if [ "$INSTALL_FLAG" = "--install" ]; then
    PLUGIN_DIR="${JELLYFIN_DATA:-$HOME/.local/share/jellyfin}/plugins/TwoFactorAuth"
    rm -rf "$PLUGIN_DIR"
    cp -r "$OUTPUT_DIR" "$PLUGIN_DIR"
    echo ""
    echo "Installed to: $PLUGIN_DIR"
    echo "Restart Jellyfin to load the plugin."
fi
