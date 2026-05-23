# Kubernetes at the edge: GitOps updates via Mender OTA

---

## The problem

_You have k3s running on edge devices. Keeping them updated is painful. GitOps tools like Flux and Argo CD were designed for data-centre connectivity — they fall apart when the network is intermittent or firewalled. Traditional OTA tools ask you to learn a new paradigm. You just want to `git push`._

---

## Why Kubernetes at the edge?

_Kubernetes has become the de-facto application platform. Your team already knows it. You have manifests, Helm charts, kustomize overlays. The question is not "should I use Kubernetes" — it is "how do I keep my edge fleet in sync with my git repository reliably?"_

---

## The update problem in practice

_Walk through a typical failure scenario: Flux polling fails when the device is offline. The registry is unreachable. The device is behind NAT. You need SSH access to debug. Each of these is a dependency that can silently break your delivery pipeline._

---

## Enter Mender

_Brief, neutral introduction. Mender is a purpose-built OTA update server: pull-based, reliable over intermittent links, designed for devices that are not always on. One outbound HTTPS connection from the device is all it needs._

---

## Is Mender a good fit here?

_Address the natural pushback: "isn't this adding yet another tool to learn?" The answer: Mender is used exactly once, to build the device image. After that it is invisible. The operator never writes a Mender configuration, never learns a Mender CLI. It is infrastructure, not workflow._

---

## Is it complicated to integrate with Kubernetes?

_Show the update module — the only Mender-aware code in the entire solution. It is ~20 lines of shell. The operator does not need to understand it; it lives in the repo and runs automatically. From here the narrative shifts: the rest is pure Kubernetes tooling._

---

## The architecture

_Diagram: two independent update streams (OS and app). Highlight that the device connects only to Mender Server — no registry, no git server, no VPN. Explain the registry-free delivery decision: OCI image bundled inside the artifact alongside kustomize output._

---

## One-time setup: building the device image

_Walk through `make build-image`. Explain what mender-convert does in plain language. Emphasise: this happens once per device type, not once per deployment. After this step the operator forgets mender-convert exists._

---

## The day-to-day workflow: just `git push`

_Demo moment. Edit `app/html/index.html`. Push to `main`. Watch GitHub Actions produce the artifact and trigger the deployment. The page updates on the device. No Mender UI interaction required. This is the payoff — the operator never left their normal tools._

---

## Observability: inventory and Device Connect

_Two bonuses that come for free. The inventory script reports the running image tag, replica count, and pod status directly in the Mender UI — useful for fleet-wide visibility without kubectl access. Device Connect provides a WebSocket shell for live debugging without VPN or exposed SSH._

---

## What's next

_Pointers for teams who want to go further: rollback with health checks via the Helm update module; external registry for teams with smaller artifact size requirements; OS-level k3s upgrades via the rootfs stream; auto-accept policies for zero-touch provisioning._
