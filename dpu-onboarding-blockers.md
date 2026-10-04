# DPU Onboarding — Remaining Blockers

**Date:** 2026-09-22
**Cluster:** nico3 (SNO, 10.6.141.100)

---

## 1. MetalLB Not Installed

MetalLB is not deployed on the cluster and is not included in the prereqs chart.
Without it, the `SITE_VIP` flag on `make deploy-site` has no effect — there is
no LoadBalancer controller to assign or announce the VIP.

**Action:**
- Install the MetalLB operator (from `redhat-operators` catalog)
- Create an `IPAddressPool` with the VIP allocated by the lab team
- Create an `L2Advertisement` for the pool
- Consider adding MetalLB to the prereqs chart (`helm/nvidia-infra-controller-prereqs/`)

---

## 2. DHCP Cannot Bind to Port 67 (Blocker)

Kea DHCPv4 fails to open its socket on startup:

```
DHCPSRV_OPEN_SOCKET_FAIL failed to open socket on interface eth0,
  reason: Failed to bind socket 22 to 10.128.1.212/port=67
DHCPSRV_NO_SOCKETS_OPEN no interface configured to listen to DHCP traffic
```

Same root cause as the nico-dns port 53 issue: `CAP_NET_BIND_SERVICE` is in
`CapBnd` but not propagated to `CapEff` by CRI-O on this cluster, so bind()
on privileged ports fails even with the capability granted.

Unlike DNS (moved to 5353), DHCP cannot move off port 67 — it's a protocol
requirement (clients broadcast to UDP 67). Possible fixes:

- **SCC with `allowPrivilegedContainer`** or a custom SCC that properly grants
  `NET_BIND_SERVICE` in the effective set
- **NET_RAW + raw socket mode** — Kea supports `dhcp-socket-type: raw` which
  uses `CAP_NET_RAW` instead of binding port 67 directly; check if CRI-O
  propagates NET_RAW to CapEff
- **hostNetwork: true** on the DHCP pod (kustomize patch) — binds directly to
  the node's network stack, bypasses the capability issue entirely, but the pod
  shares the host IP

---

## 3. DHCP Subnet Configuration

Currently a catch-all placeholder:

```yaml
subnet4:
  - subnet: "0.0.0.0/0"
    pools:
      - "0.0.0.0-255.255.255.255"
```

Needs the real lab subnet and pool range once the lab team allocates IPs. The
DPU data plane and host will get addresses from this pool.

---

## 4. NTP Not Available

`nico-ntp` is disabled. The DHCP hook parameter `ntpServer` is set to the
upstream placeholder (`REPLACE_WITH_NICO_NTP_VIPS`). Upstream warns that DPU
preingestion can fail on clock divergence without NTP.

**Options:**
- Enable `nico-ntp` subchart (but it had OpenShift SCC issues — chrony
  entrypoint chowns `/run/chrony` which fails under arbitrary UID)
- Point `ntpServer` at an existing lab/corporate NTP server if one is available
- Assess whether the DPU's BMC keeps time close enough for preingestion

---

## 5. Boot Artifact Containers Empty

Both `nico-api` and `nico-pxe` have `bootArtifactContainers: []`. The PXE
server has no BFB image to serve the DPU and no scout.efi for the host.

**Action:**
- Build or obtain the BFB (BlueField Boot) image for BlueField-3
- Build or obtain the x86_64 scout.efi for the Dell R750 host
- Configure `bootArtifactContainers` init containers that copy images into
  the PXE serving directory

---

## Summary

| # | Blocker | Severity | Depends On |
|---|---|---|---|
| 1 | MetalLB not installed | High | Lab team VIP allocation |
| 2 | DHCP port 67 bind failure | **Critical** | SCC / capability fix |
| 3 | DHCP subnet4 placeholder | Medium | Lab team subnet info |
| 4 | NTP not available | Low | Lab NTP server or nico-ntp SCC fix |
| 5 | Boot artifacts missing | High | BFB / scout.efi images |
