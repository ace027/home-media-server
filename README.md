# home-media-server

This is a GitOps Docker Compose repository for a home media platform on Proxmox. It covers a complete Usenet ARR stack, with Plex as the media server (Jellyfin runs only as an optional side-by-side evaluation). Traefik and Authentik handle public access, Twingate provides the only way into the admin tools, DDNS tracks the dynamic IP, and FileFlows converts the library to AV1 on an Intel Arc A380. Everything is reproducible from this repo except secrets.

## Quick start
1. Follow the host runbook: [`docs/runbooks/01-proxmox-host.md`](docs/runbooks/01-proxmox-host.md) (ZFS datasets, IOMMU/vfio, VM creation).
2. Follow the VM runbook: [`docs/runbooks/02-vm-bootstrap.md`](docs/runbooks/02-vm-bootstrap.md) (Docker install, `/data` mount, verification).
3. In the repo, copy the env contract and edit it: `cp .env.example .env`.
4. Validate the Compose tree: `docker compose config`.

## Layout
```
compose.yaml     # root Compose file, includes stacks/*.yaml
stacks/          # domain-split Compose stack files + shared _common.yaml template
docs/            # architecture overview and runbooks
scripts/         # host, VM, CI and shared library scripts
secrets/         # gitignored; Docker secrets or *_FILE sources (never committed)
.env.example     # env contract for all stacks and scripts
```

## Documentation
See [`docs/README.md`](docs/README.md) for the full documentation index.

## Branches
`main` is the default branch and holds released work. Development happens on `dev`: feature branches are cut from `dev` and merged back into it by PR, and `dev` is merged into `main` when a phase is complete. See [`CLAUDE.md`](CLAUDE.md).
