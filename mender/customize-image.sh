#!/usr/bin/env bash
set -euo pipefail

INPUT_IMAGE="${1:?Usage: $0 <mender-image.img.xz> [username] [ssh-public-key-file]}"
USERNAME="${2:-pi}"
SSH_KEY_FILE="${3:-}"

# Set ENABLE_SSH_ACCESS=true to drop an authorized_keys and enable sshd on first boot
ENABLE_SSH_ACCESS="${ENABLE_SSH_ACCESS:-false}"

# Optional — set a static hostname (skipped if empty; defaults to raspberrypi)
DEVICE_HOSTNAME="${DEVICE_HOSTNAME:-}"

# Optional — bake in Mender server credentials (skipped if empty)
MENDER_SERVER_URL="${MENDER_SERVER_URL:-}"
MENDER_TENANT_TOKEN="${MENDER_TENANT_TOKEN:-}"

# Optional — install k3s on first boot (skipped if empty; e.g. K3S_VERSION=v1.35.0+k3s1)
K3S_VERSION="${K3S_VERSION:-}"

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
OUTPUT_DIR="$(dirname "$SCRIPT_DIR")/output"
sudo mkdir -p "$OUTPUT_DIR"
sudo chown "$(id -un):$(id -gn)" "$OUTPUT_DIR"

WORK_IMG="$(mktemp --suffix=.img)"
BOOT_MNT="$(mktemp -d)"
ROOTFS_MNT="$(mktemp -d)"
LOOP=""

cleanup() {
    sudo umount "$ROOTFS_MNT" 2>/dev/null || true
    sudo umount "$BOOT_MNT"   2>/dev/null || true
    [[ -n "$LOOP" ]] && sudo losetup -d "$LOOP" 2>/dev/null || true
    rm -rf "$BOOT_MNT" "$ROOTFS_MNT"
    rm -f  "$WORK_IMG"  # no-op after successful mv
}
trap cleanup EXIT

echo "Decompressing image..."
xzcat "$INPUT_IMAGE" > "$WORK_IMG"

LOOP="$(sudo losetup -Pf --show "$WORK_IMG")"

# ── Partition 1: FAT32 boot ───────────────────────────────────────────────────
sudo mount "${LOOP}p1" "$BOOT_MNT"

if [[ "$ENABLE_SSH_ACCESS" == "true" ]]; then
    sudo touch "$BOOT_MNT/ssh"
fi
printf '%s:%s\n' "$USERNAME" "$(openssl passwd -6 raspberry)" \
    | sudo tee "$BOOT_MNT/userconf.txt" > /dev/null

# k3s requires cgroups — patch cmdline.txt (idempotent)
if [[ -n "$K3S_VERSION" ]]; then
    CMDLINE="$(cat "$BOOT_MNT/cmdline.txt")"
    CMDLINE="${CMDLINE//cgroup_memory=1/}"
    CMDLINE="${CMDLINE//cgroup_enable=memory/}"
    CMDLINE="$(echo "$CMDLINE" | tr -s ' ' | sed 's/[[:space:]]*$//')"
    printf '%s cgroup_memory=1 cgroup_enable=memory\n' "$CMDLINE" \
        | sudo tee "$BOOT_MNT/cmdline.txt" > /dev/null
fi

# ── firstrun.sh — runs on first boot ─────────────────────────────────────────
# Picked up automatically by raspberrypi-sys-mods if present; device-setup.service
# acts as a fallback so it runs regardless. Script self-deletes, preventing re-runs.
# Credentials are NOT embedded here; they live in mender.conf on the rootfs.
sudo tee "$BOOT_MNT/firstrun.sh" > /dev/null <<'HEADER'
#!/bin/bash
set -euo pipefail
exec >> /boot/firmware/firstrun.log 2>&1
echo "=== firstrun start $(date) ==="

# Mender APT repository + mender-connect
curl -fsSL https://downloads.mender.io/repos/debian/gpg \
    | tee /etc/apt/trusted.gpg.d/mender.asc > /dev/null
echo "deb [arch=arm64] https://downloads.mender.io/repos/device-components debian/trixie/stable main" \
    > /etc/apt/sources.list.d/mender.list
DEBIAN_FRONTEND=noninteractive apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends mender-connect

HEADER

if [[ -n "$K3S_VERSION" ]]; then
    sudo tee -a "$BOOT_MNT/firstrun.sh" > /dev/null <<K3S
# k3s ${K3S_VERSION}
mkdir -p /etc/rancher/k3s
printf 'data-dir: /data/k3s\n' > /etc/rancher/k3s/config.yaml
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="${K3S_VERSION}" sh -
mkdir -p /etc/systemd/system/k3s.service.d
printf '[Unit]\nRequires=data.mount\nAfter=data.mount\n' \
    > /etc/systemd/system/k3s.service.d/data-mount.conf
systemctl daemon-reload

K3S
fi

sudo tee -a "$BOOT_MNT/firstrun.sh" > /dev/null <<'FOOTER'
echo "=== firstrun complete $(date) ==="
rm -f /boot/firmware/firstrun.sh
FOOTER

sudo umount "$BOOT_MNT"

# ── Partition 2: rootfs-A ─────────────────────────────────────────────────────
# UID/GID 1000 is the first user on Raspberry Pi OS (created by userconf.txt on first boot)
sudo mount "${LOOP}p2" "$ROOTFS_MNT"

if [[ "$ENABLE_SSH_ACCESS" == "true" && -n "$SSH_KEY_FILE" ]]; then
    sudo install -d -m 700 -o 1000 -g 1000 "$ROOTFS_MNT/home/${USERNAME}/.ssh"
    sudo install -m 600 -o 1000 -g 1000 "$SSH_KEY_FILE" \
        "$ROOTFS_MNT/home/${USERNAME}/.ssh/authorized_keys"
fi

# Passwordless sudo — needed for mender snapshot dump and make setup-device
printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$USERNAME" \
    | sudo tee "$ROOTFS_MNT/etc/sudoers.d/010_${USERNAME}-nopasswd" > /dev/null
sudo chmod 0440 "$ROOTFS_MNT/etc/sudoers.d/010_${USERNAME}-nopasswd"

if [[ -n "$DEVICE_HOSTNAME" ]]; then
    echo "$DEVICE_HOSTNAME" | sudo tee "$ROOTFS_MNT/etc/hostname" > /dev/null
    sudo sed -i "s/^127\.0\.1\.1.*/127.0.1.1\t${DEVICE_HOSTNAME}/" "$ROOTFS_MNT/etc/hosts"
fi

# Mender update module + inventory script
sudo install -d -m 755 "$ROOTFS_MNT/usr/share/mender/modules/v3"
sudo install -m 755 "$SCRIPT_DIR/k8s-update-module" \
    "$ROOTFS_MNT/usr/share/mender/modules/v3/k8s-workload"
sudo install -d -m 755 "$ROOTFS_MNT/usr/share/mender/inventory"
sudo install -m 755 "$SCRIPT_DIR/convert-overlay/rootfs_overlay/usr/share/mender/inventory/mender-inventory-k8s-app" \
    "$ROOTFS_MNT/usr/share/mender/inventory/mender-inventory-k8s-app"

# Mender server credentials — merge into existing mender.conf to preserve RootfsPartA/B etc.
if [[ -n "$MENDER_SERVER_URL" && -n "$MENDER_TENANT_TOKEN" ]]; then
    sudo mkdir -p "$ROOTFS_MNT/etc/mender"
    CONF="$ROOTFS_MNT/etc/mender/mender.conf"
    EXISTING="{}"
    [[ -f "$CONF" ]] && EXISTING="$(sudo cat "$CONF")"
    printf '%s' "$EXISTING" \
        | jq --arg url "$MENDER_SERVER_URL" --arg tok "$MENDER_TENANT_TOKEN" \
             '. + {ServerURL: $url, TenantToken: $tok, Servers: [{ServerURL: $url}]}' \
        | sudo tee "$CONF" > /dev/null
    sudo chmod 600 "$CONF"
    sudo chown root:root "$CONF"
fi


sudo tee "$ROOTFS_MNT/etc/systemd/system/firstrun.service" > /dev/null <<'EOF'
[Unit]
Description=First-boot setup
After=network-online.target
Wants=network-online.target
ConditionPathExists=/boot/firmware/firstrun.sh

[Service]
Type=oneshot
ExecStart=/bin/bash /boot/firmware/firstrun.sh
RemainAfterExit=yes
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=multi-user.target
EOF

sudo mkdir -p "$ROOTFS_MNT/etc/systemd/system/multi-user.target.wants"
sudo ln -sf /etc/systemd/system/firstrun.service \
    "$ROOTFS_MNT/etc/systemd/system/multi-user.target.wants/firstrun.service"

sudo umount "$ROOTFS_MNT"
sudo losetup -d "$LOOP"
LOOP=""

OUTPUT_IMAGE="$OUTPUT_DIR/$(basename "$INPUT_IMAGE" .img.xz)-custom.img"
mv "$WORK_IMG" "$OUTPUT_IMAGE"

echo "Done: $OUTPUT_IMAGE"
echo "Default password for '${USERNAME}': raspberry — change on first login"
[[ -n "$MENDER_SERVER_URL" ]] && echo "Mender server: $MENDER_SERVER_URL (baked into mender.conf)"
[[ -n "$K3S_VERSION" ]]       && echo "k3s ${K3S_VERSION} — installs on first boot via firstrun.sh"
