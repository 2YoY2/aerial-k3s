# site/ — untracked, per-deployment values

Everything in this directory is ignored by git (except this file).

Put anything that identifies one deployment here: fronthaul MAC and VLAN,
PCIe addresses, cell identity, management IPs, NGC credentials, kubeconfigs.
The scripts and charts in this repo read from here so the tracked tree stays
generic and safe to publish.
