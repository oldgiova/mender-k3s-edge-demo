#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
OVERLAY="$SCRIPT_DIR/convert-overlay/rootfs_overlay/usr/share/mender"

sudo mkdir -p /usr/share/mender/modules/v3
sudo mkdir -p /usr/share/mender/inventory

sudo cp "$OVERLAY/modules/v3/k8s-workload" /usr/share/mender/modules/v3/k8s-workload
sudo chmod +x /usr/share/mender/modules/v3/k8s-workload

sudo cp "$OVERLAY/inventory/mender-inventory-k8s-app" /usr/share/mender/inventory/mender-inventory-k8s-app
sudo chmod +x /usr/share/mender/inventory/mender-inventory-k8s-app

echo "Done. Next steps on this device:"
echo "  1. Install k3s:   curl -sfL https://get.k3s.io | sh -"
echo "  2. Clean state:   sudo systemctl stop k3s && sudo rm -rf /var/lib/rancher/k3s/ /etc/rancher/k3s/"
echo "  3. Power off:     sudo poweroff"
echo "  4. Image the SD card from another machine, then run make build-image."
