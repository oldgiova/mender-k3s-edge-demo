# Kubernetes workloads at the edge: OTA updates via Mender

---

## The problem

_You have k3s running on edge devices. Keeping workloads updated is painful. Cloud-native delivery tools assume data-centre connectivity — they fall apart when the network is intermittent, firewalled, or behind NAT. You need SSH access just to debug a failed rollout. You just want to push a commit and have it land on the device._

---

## Why Kubernetes at the edge?

_Kubernetes has become the de-facto application platform. Your team already knows it. You have manifests, kustomize overlays, Helm charts. The question is not "should I use Kubernetes at the edge" — it is "how do I reliably ship updated workloads to devices that are not always reachable?"_

---

## The delivery problem in practice

_Walk through a typical failure scenario: the device is offline when the CI pipeline fires. The container registry is unreachable from the device network. The device is behind NAT with no inbound access. Each dependency that lives outside the device is a silent failure point._

---

## Enter Mender

_Brief, neutral introduction. Mender is a purpose-built OTA update server: reliable over intermittent links, designed for devices that are not always on. One outbound HTTPS connection from the device to the Mender server is all it needs. No inbound ports, no VPN, no registry._

---

## Is Mender a good fit here?

_Address the natural pushback: "isn't this adding yet another tool to learn?" The answer: Mender is used exactly once, to build the device image. After that it is invisible. The operator never writes a Mender configuration, never learns a Mender CLI. It is infrastructure, not workflow._

---

## Is it complicated to integrate with Kubernetes?

_Show the update module — the only Mender-aware code in the entire solution. It is ~20 lines of shell. The operator does not need to understand it; it lives in the repo and runs automatically. From here the narrative shifts: the rest is pure Kubernetes tooling._

---

## The architecture

_Diagram: two independent update streams (OS and app). Highlight that the device connects only to Mender Server — no registry, no git server, no VPN. Explain the registry-free delivery decision: OCI image bundled inside the artifact alongside kustomize output. `ctr images import` + `kubectl apply` on the device side._

---

## One-time setup: building the device image

_Walk through `make customize-image` and the golden rootfs snapshot flow. Explain what mender-convert does in plain language. Emphasise: this happens once per device type, not once per deployment. After this step the operator forgets Mender internals exist._

---

## The day-to-day workflow: just `git push`

_Demo moment. Edit `app/html/index.html`. Push to `main`. Watch GitHub Actions build the arm64 image, render the kustomize manifests, package the artifact, and trigger the deployment. The page updates on the device. No Mender UI interaction required. The operator never left their normal tools._

---

## Observability: inventory and Device Connect

_Two bonuses that come for free. The inventory script reports the running image tag, replica count, and pod status directly in the Mender UI — useful for fleet-wide visibility without kubectl access. Device Connect provides a WebSocket shell for live debugging without VPN or exposed SSH._

---

## What's next

_Pointers for teams who want to go further: rollback with health checks via the Helm update module; external registry for teams with smaller artifact size requirements; OS-level k3s upgrades via the rootfs stream; auto-accept policies for zero-touch provisioning._
