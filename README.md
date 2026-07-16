# mender-k3s-edge-demo

Kubernetes workload updates at the edge, delivered over-the-air by [Mender](https://mender.io).

Push to `main` and your edge device running k3s gets the updated workload — no container registry, no VPN, no Mender knowledge required after the initial device setup.

## How it works

Two independent update streams:

| Stream | Trigger | Delivery |
|--------|---------|----------|
| **App** | `git push` to `main` | GitHub Actions → `.mender` artifact → hosted Mender → `kubectl apply` on device |
| **OS** | Manual | `mender snapshot` → rootfs-image artifact → hosted Mender → A/B update on device |

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
│   ├── customize-image.sh       # injects user + SSH key into a Mender .img.xz
│   ├── setup-device.sh          # installs update module and inventory on a live Pi
│   ├── build-image.sh           # wraps mender-convert (advanced: custom OS builds)
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

- A [hosted Mender](https://hosted.mender.io) account (free tier works)
- A Raspberry Pi 4
- A GitHub account, and a **fork of this repository** — the app deployment pipeline runs as a GitHub Actions workflow in your own fork, and the per-repository secrets and variables it needs live there (see [Step 2](#step-2--configure-github-actions-once-per-repository))
- `mender-artifact` on your build machine (only for `make snapshot-image` — see [downloads](https://docs.mender.io/downloads))

## Frequency guide

| Step | When |
|------|------|
| Fork this repository | **Once** |
| Build & flash the device image | **Once** per device type |
| Configure GitHub Actions secrets | **Once** per repository |
| Accept the device in hosted Mender | **Once** per device |
| `git push` to deploy an app update | **Every** code change — fully automated |
| OS update (k3s upgrade, CVE patch) | **Rarely** — independent of app changes |

---

## Step 1 — Build the device image *(once per device type)*

This step produces a **golden rootfs artifact** — the device OS with k3s pre-installed, packaged as a Mender OTA update. New devices are flashed once with the Mender base image and then receive k3s over-the-air. No SD card removal, no Docker, no mender-convert.

### 1a — Download and customise the pre-built Mender image

Mender distributes a Raspberry Pi 4 Trixie Lite image with A/B partitions and the Mender client already set up. One `make` call patches the image with everything the device needs — user account, SSH key, Mender server credentials, and k3s pre-installed:

```bash
curl -LO https://d4o6e0uccgv40.cloudfront.net/2025-10-01-raspios-lite/arm/2025-10-01-raspios-lite-raspberrypi4_trixie_64bit-mender-convert-5.2.1.img.xz

make customize-image \
  INPUT=2025-10-01-raspios-lite-raspberrypi4_trixie_64bit-mender-convert-5.2.1.img.xz \
  DEVICE_USER=pi \
  DEVICE_HOSTNAME=edge-01 \
  MENDER_SERVER_URL=https://eu.hosted.mender.io \
  MENDER_TENANT_TOKEN=<your-token> \
  K3S_VERSION=v1.35.0+k3s1 \
  ENABLE_SSH_ACCESS=true \
  SSH_KEY=~/.ssh/id_ed25519.pub
```

What the script does to the image:

| Partition | Change |
|-----------|--------|
| FAT32 boot (p1) | `userconf.txt` (creates user on first boot), `ssh` (enables sshd — only when `ENABLE_SSH_ACCESS=true`), `cmdline.txt` patched with `cgroup_memory=1 cgroup_enable=memory` |
| rootfs-A (p2) | `~/.ssh/authorized_keys`, passwordless-sudo entry, `/etc/mender/mender.conf` with `ServerURL` + `TenantToken`, k3s binary + service + `data-dir: /data/k3s` config, Mender APT repo + one-shot service that installs `mender-connect` on first boot |

> **Default password** is `raspberry` — change it on first login. `DEVICE_USER` defaults to `pi`, `SSH_KEY` to `~/.ssh/id_ed25519.pub`. `K3S_VERSION` and Mender credentials are optional — omit them to skip those steps. Add `DEMO=true` to bake in mender-convert's demo polling intervals (update/inventory 5 s, retry 30 s) for a fast test loop instead of the slow production defaults.

Your tenant token is in hosted Mender under **Settings → My organization**.

The customised image lands in `output/`. Flash it:

```bash
IMG=$(ls output/*-custom.img)
sudo dd if="$IMG" of=/dev/sdX bs=4M conv=fsync status=progress
```

Alternatively, use [Raspberry Pi Imager](https://www.raspberrypi.com/software/) for the SSH key and user setup (GUI), though it cannot inject Mender credentials or k3s — use the Makefile target for a fully automated image.

### 1b — Install the Mender update modules

After flashing and booting, SSH in and install the `k8s-workload` update module and inventory script:

```bash
git clone https://github.com/<your-org>/mender-k3s-edge-demo.git
cd mender-k3s-edge-demo
make setup-device
```

The device connects to hosted Mender automatically (credentials are already in `mender.conf`) and appears under **Devices → Pending** — accept it once.

### 1c — Flash and provision new devices

For every additional device, repeat steps 1a–1b. No master device, no snapshot, no golden image deployment required.

## Step 2 — Configure GitHub Actions *(once per repository)*

The app deployment pipeline runs as a GitHub Actions workflow, so it has to live in a repository you control. If you haven't already, **fork this repository** to your own GitHub account (click **Fork** at the top-right of the repository page). Every `git push` to `main` on your fork then triggers the workflow, and the secret and variables below are read from your fork.

In your fork's **Settings → Secrets and variables → Actions**, add:

| Type | Name | Value |
|------|------|-------|
| Secret | `MENDER_TOKEN` | Personal access token from hosted Mender (Profile → Access tokens) |
| Variable | `MENDER_SERVER_URL` | `https://hosted.mender.io` or `https://eu.hosted.mender.io` |
| Variable | `MENDER_DEVICE_TYPE` | `raspberrypi4_64` (must match the device type accepted in Mender) |
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

GitHub Actions builds the artifact and triggers the deployment. Watch progress in **Deployments** on hosted Mender. Once complete, the new page is live at `http://<device-ip>/`.

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

To update the OS (kernel, packages, Mender client), prepare a fresh master device with the new base image, follow steps 1b–1d, and deploy the resulting rootfs artifact. Devices update over-the-air and automatically roll back if the new rootfs fails to check in.

---

## Advanced: custom OS build with mender-convert

If you need a base OS that Mender doesn't distribute pre-built (custom kernel, BSP, Ubuntu), you can run `mender-convert` yourself to create the A/B-partitioned base image. This requires Docker and replaces step 1a above.

```bash
make build-image INPUT=/path/to/raspios.img.xz
```

mender-convert creates the A/B partition layout and installs the Mender client, but does **not** bake in server credentials — those are configured on the device at first boot. Flash the resulting `output/*.img.xz` to each device SD card, then follow step 1b to configure the Mender client with `mender-setup`.
