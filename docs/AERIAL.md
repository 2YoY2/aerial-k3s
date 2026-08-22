# NVIDIA Aerial on Kubernetes — the path from this lab to GPU L1

NVIDIA Aerial (cuBB: cuPHY + cuMAC) is a **GPU-accelerated 5G L1**. It does not
replace the whole gNB: the proven pairing is **OAI L2/L3 (MAC and up) + Aerial L1**,
talking over NVIDIA's `nvIPC` shared-memory FAPI interface. That's exactly the
combination NVIDIA and OAI ship as **ARC‑OTA** (Aerial RAN CoLab Over‑the‑Air).
Everything you build in the main plan (core, Helm, namespaces, scaling) stays;
only the gNB pod changes.

## 1. Hardware you actually need (per DU site)

| Piece | Requirement |
|---|---|
| GPU | A100 / H100 / GH200, or a converged card (A100X, H100‑CX7). **GeForce/RTX laptop GPUs will not work** — cuPHY needs data-center silicon. |
| NIC | NVIDIA ConnectX‑6 Dx / ConnectX‑7 (or the one on the converged card) with SR‑IOV, for eCPRI fronthaul |
| Timing | PTP grandmaster (G.8275.1) + `ptp4l`/`phc2sys` on the host — O‑RAN 7.2 fronthaul is time-synchronous |
| Radio | O‑RAN 7.2 O‑RU (e.g. Foxconn) — Aerial has no RF simulator mode for casual use |
| CPU/OS | x86 with isolated cores (`isolcpus`, `nohz_full`), 1 GB hugepages, low-latency kernel |
| Access | NGC account with Aerial access (NVIDIA developer program / ARC‑OTA) — containers are **not** public |

## 2. Cluster prep (this part you can practice on any GPU node)

Aerial nodes are normal k8s workers plus three operators/configs:

```bash
# GPU Operator: drivers, container toolkit, device plugin, MIG config
helm repo add nvidia https://helm.ngc.nvidia.com/nvidia
helm install gpu-operator nvidia/gpu-operator -n gpu-operator --create-namespace

# Network Operator: MOFED driver, SR-IOV device plugin, RDMA shared device,
# secondary networks (Multus) for the fronthaul VFs
helm install network-operator nvidia/network-operator -n nvidia-network-operator --create-namespace
```

Plus node tuning (hugepages, isolated cores, PTP services on the host). Verify with
`kubectl describe node | grep -A10 Allocatable` — you should see `nvidia.com/gpu`
and hugepages resources.

## 3. What the gNB deployment becomes

One pod (or two containers in one pod) per DU site:

- **cuphycontroller / cuBB container** (from NGC): owns the GPU + fronthaul NIC VF.
  Requests `nvidia.com/gpu: 1`, hugepages, an SR‑IOV VF on the fronthaul VLAN
  (Multus secondary interface), and pinned CPUs (`Guaranteed` QoS).
- **OAI gNB container** built with Aerial/nvIPC support (OAI `develop` branch,
  `--build-lib nvipc` / the `oai-gnb-aerial` image): runs L2+, config points its
  FAPI south-bound at nvIPC shared memory (`/dev/shm` volume shared between the
  two containers) instead of the built-in PHY.
- North-bound **nothing changes**: same N2 to `oai-amf`, same N3 to the UPF —
  the same core you deployed in the main plan serves it.

Scaling model is identical to Phase 6: **one Helm release per cell/DU site**, one
GPU per DU, same AMF. You scale by adding GPU nodes and releases, and the CU
(from `e2e_scenarios/case3`) aggregates DUs.

## 4. Sensible order of attack

1. Finish the main plan through Phase 6 (you'll reuse every skill).
2. Do `case2`/`case3` — CU/DU split. Aerial replaces the DU's L1, so being fluent
   with `oai-du` + F1 config is the real preparation.
3. On any server with *any* NVIDIA data-center GPU, practice GPU Operator +
   Network Operator installs and hugepage/CPU-isolation node tuning.
4. Get NGC/ARC‑OTA access, then bring up cuBB on the Aerial node **bare-metal
   first** (NVIDIA's cuBB quickstart), before containerizing into the cluster.
5. Swap the DU in your Helm topology for the Aerial+OAI‑nvIPC pod.

## 5. References to keep open

- NVIDIA Aerial docs: https://docs.nvidia.com/aerial/
- ARC‑OTA (Aerial + OAI end-to-end): https://docs.nvidia.com/aerial/aerial-ran-colab-ota/
- GPU Operator: https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/
- Network Operator: https://docs.nvidia.com/networking/software/cloud-orchestration/
- OAI + Aerial integration notes: `openairinterface5g` repo, `doc/Aerial_FAPI_Split_Tutorial.md`
- O‑RAN 7.2 charts in this folder: `orchestration/oai-5g-ran/oai-du-fhi-72`
