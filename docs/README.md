# Documentation

- [`architecture.md`](architecture.md) — repository layout, storage layout, networking and exposure, and the shared service template.
- [`runbooks/01-proxmox-host.md`](runbooks/01-proxmox-host.md) — BIOS, ZFS datasets, IOMMU/vfio, directory mapping and VM creation on the Proxmox host.
- [`runbooks/02-vm-bootstrap.md`](runbooks/02-vm-bootstrap.md) — Debian 13 install, bootstrap script, data tree and verification inside the VM.
- [`runbooks/03-core-media.md`](runbooks/03-core-media.md) — Phase 2 cutover: restore the old app configs, remap and wire SABnzbd, the *arr apps and Prowlarr, split out 4K titles, set up Plex and Seerr, and the acceptance run.

Phase 5 adds more runbooks here (backup/restore drills and observability setup).
