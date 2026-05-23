# mender-gitops-demo

GitOps-style Kubernetes updates at the edge, delivered over-the-air by [Mender](https://mender.io).

You write `kubectl`-compatible manifests, push to `main`, and your edge device running k3s gets the new workload — no registry, no VPN, no Mender knowledge required after the initial image build.

## How it works

Two independent update streams:

| Stream | Trigger | Delivery |
|--------|---------|----------|
| **App** | `git push` to `main` | GitHub Actions → `.mender` artifact → hosted Mender → `kubectl apply` on device |
| **OS** | Manual | `mender-convert` → rootfs A/B update via Mender |

The app stream bundles the OCI image (`docker save`) and the rendered kustomize manifests into a single `.mender` artifact. No external registry needed — the image travels inside the artifact. On the device, the `k8s-workload` update module runs `ctr images import` followed by `kubectl apply`.

```
git push main
    └─► GitHub Actions
            ├─ docker build nginx-edge:sha-<SHA>
            ├─ docker save → payload/image.tar
            ├─ kustomize build → payload/manifests.yaml
            ├─ mender-artifact write module-image → app-nginx-sha-<SHA>.mender
            ├─ curl POST /api/management/v1/deployments/artifacts   (upload)
            └─ curl POST /api/management/v2/deployments/deployments (deploy to group)
```

## Repository layout

```
.
├── app/
│   ├── Dockerfile
│   └── html/index.html          # sample nginx page
├── k8s/
│   ├── base/                    # deployment + service
│   └── overlays/edge/           # namespace + image tag pin
├── mender/
│   ├── k8s-update-module        # canonical source of the update module script
│   ├── build-image.sh           # wraps mender-convert for Raspberry Pi 4
│   └── convert-overlay/
│       └── rootfs_overlay/      # files copied verbatim into the converted image
│           ├── etc/systemd/system/k3s-install.service
│           └── usr/share/mender/
│               ├── modules/v3/k8s-workload
│               └── inventory/mender-inventory-k8s-app
├── Makefile
└── .github/workflows/deploy.yml
```

## Prerequisites

- [Docker](https://docs.docker.com/get-docker/) on the machine where you run `make build-image` (wraps `mender-convert`; not needed on the device or for the CI pipeline)
- A [hosted Mender](https://hosted.mender.io) account (free tier works)
- A Raspberry Pi 4 and a Raspberry Pi OS Bookworm 64-bit image

## Frequency guide

| Step | When |
|------|------|
| Build & flash the device image | **Once** per device type |
| Configure GitHub Actions secrets | **Once** per repository |
| Accept the device in hosted Mender | **Once** per device |
| `git push` to deploy an app update | **Every** code change — fully automated |
| OS update (k3s upgrade, CVE patch) | **Rarely** — independent of app changes |

---

## Step 1 — Build the device image *(once per device type)*

Download the [official Raspberry Pi OS 64-bit image](https://downloads.raspberrypi.com/raspios_arm64/images/raspios_arm64-2026-04-21/2026-04-21-raspios-trixie-arm64.img.xz), then run:

```bash
MENDER_TENANT_TOKEN=<your-token> make build-image INPUT=/path/to/2026-04-21-raspios-trixie-arm64.img.xz
```

Under the hood this runs `mender-convert` inside Docker, roughly:

```bash
mender-convert \
  --disk-image  raspios-trixie-arm64.img \
  --config      configs/raspberrypi/uboot/debian/raspberrypi4_trixie_64bit_config \
  --overlay     mender/convert-overlay/rootfs_overlay
```

`mender-convert` repartitions the image into an A/B layout, installs the Mender client, and bakes in the server URL and tenant token so the device auto-connects on first boot. The overlay injects the k3s installer service and the `k8s-workload` update module into the resulting filesystem.

This:
1. Creates the `multi-user.target.wants` symlink so `k3s-install.service` starts on first boot
2. Places the `k8s-workload` update module and inventory script at the correct paths
3. Runs `mendersoftware/mender-convert:5.2.1` in Docker with the RPi 4 Trixie U-Boot config

The converted image lands in `output/`. Flash it to an SD card:

```bash
# Identify your SD card device (look for the size matching your card)
lsblk

# Unmount any auto-mounted partitions, then flash
sudo umount /dev/sdX* 2>/dev/null || true
xzcat output/*.img.xz | sudo dd of=/dev/sdX bs=4M conv=fsync status=progress
```

Replace `/dev/sdX` with your actual device (e.g. `/dev/sdb`, `/dev/mmcblk0`). Alternatively use [Raspberry Pi Imager](https://www.raspberrypi.com/software/) and select the `.img.xz` from `output/` as a custom image — it handles compressed images natively.

On first boot the device will:
1. Install k3s (one-shot systemd service, self-disabling after success)
2. Register with hosted Mender (accept it once in the UI under **Devices → Pending**)

## Step 2 — Configure GitHub Actions *(once per repository)*

In your repository **Settings → Secrets and variables → Actions**, add:

| Type | Name | Value |
|------|------|-------|
| Secret | `MENDER_TOKEN` | Personal access token from hosted Mender (Profile → Access tokens) |
| Variable | `MENDER_DEVICE_TYPE` | `raspberrypi4` (must match the device type accepted in Mender) |
| Variable | `MENDER_DEVICE_GROUP` | Name of the device group to deploy to (e.g. `edge-devices`) |

Create a device group in hosted Mender (**Devices → Groups**) and add your accepted device to it.

## Step 3 — Deploy an app update *(every push — no manual steps)*

Push any change to `main`:

```bash
# Edit the sample page
echo '<h1>Hello from the edge — v2</h1>' > app/html/index.html
git add app/html/index.html
git commit -m "feat: bump to v2"
git push origin main
```

GitHub Actions builds the artifact and triggers the deployment. Watch progress in **Deployments** on hosted Mender. Once complete, the new page is live at `http://<device-ip>:30080`.

## Device inventory

The `mender-inventory-k8s-app` script runs automatically on each Mender inventory poll (~every 8 hours by default). It reports three attributes visible in the device panel on hosted Mender:

| Attribute | Example value |
|-----------|--------------|
| `k8s_app_image` | `nginx-edge:sha-a1b2c3d` |
| `k8s_app_replicas` | `1/1` |
| `k8s_app_pod_status` | `Running` |

You can filter and group devices by any of these attributes, which makes it easy to track which image version is running across a fleet without opening a shell.

## Debugging with Device Connect

Mender's Device Connect feature provides a WebSocket shell directly to the device — no VPN or SSH key distribution needed.

In hosted Mender, open the device and click **Connect**. From there you can inspect the cluster:

```bash
kubectl get pods -n edge-app
kubectl logs -n edge-app deploy/nginx-edge
```

## Adding your own application

1. Replace `app/` with your own `Dockerfile`
2. Update `k8s/base/deployment.yaml` — change `nginx-edge` to your image name
3. Update the `images[].name` field in `k8s/overlays/edge/kustomization.yaml` to match
4. Push to `main`

## OS updates *(infrequent — independent of app changes)*

To update the OS (kernel, packages, Mender client itself), re-run `make build-image INPUT=...` with a newer base image and upload the resulting `.mender` rootfs artifact to hosted Mender manually, or add a separate GitHub Actions workflow for it.
