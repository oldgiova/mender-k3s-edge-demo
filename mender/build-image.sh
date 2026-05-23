#!/usr/bin/env bash
set -euo pipefail

INPUT_IMAGE="${1:?Usage: $0 <path-to-raspberrypi4-image.img.xz>}"
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
OVERLAY_DIR="$SCRIPT_DIR/convert-overlay/rootfs_overlay"

MENDER_ARTIFACT_NAME="${MENDER_ARTIFACT_NAME:-$(basename "$INPUT_IMAGE" .img.xz)}"
MENDER_STORAGE_TOTAL_SIZE_MB="${MENDER_STORAGE_TOTAL_SIZE_MB:-16384}"

# systemd enable via symlink — mender-convert copies files verbatim, no scriptlets run
WANTS_DIR="$OVERLAY_DIR/etc/systemd/system/multi-user.target.wants"
mkdir -p "$WANTS_DIR"
ln -sf /etc/systemd/system/k3s-install.service \
    "$WANTS_DIR/k3s-install.service"

chmod +x \
    "$OVERLAY_DIR/usr/share/mender/modules/v3/k8s-workload" \
    "$OVERLAY_DIR/usr/share/mender/inventory/mender-inventory-k8s-app"

# mender_convert_config hardcodes MENDER_STORAGE_TOTAL_SIZE_MB=8192; a later
# --config file is the only way to override it — env vars are not inherited by bash source
STORAGE_CONFIG="$(mktemp --suffix=_mender_storage_config)"
trap 'rm -f "$STORAGE_CONFIG"' EXIT
cat > "$STORAGE_CONFIG" <<EOF
MENDER_STORAGE_TOTAL_SIZE_MB="$MENDER_STORAGE_TOTAL_SIZE_MB"
MENDER_BOOT_PART_SIZE_MB="512"
EOF

docker run --rm \
    --privileged \
    -v /dev:/dev \
    -e MENDER_ARTIFACT_NAME="$MENDER_ARTIFACT_NAME" \
    -v "$INPUT_IMAGE:/mender-convert/input/image.img.xz:ro" \
    -v "$SCRIPT_DIR/convert-overlay:/mender-convert/input/overlay" \
    -v "$STORAGE_CONFIG:/mender-convert/input/storage_config:ro" \
    -v "$(pwd)/output:/mender-convert/deploy" \
    mendersoftware/mender-convert:5.2.1 \
    --config configs/raspberrypi/uboot/debian/raspberrypi4_trixie_64bit_config \
    --config /mender-convert/input/storage_config \
    --overlay /mender-convert/input/overlay \
    --disk-image /mender-convert/input/image.img.xz

echo "Artifact:  $MENDER_ARTIFACT_NAME"
echo "Image written to output/"
