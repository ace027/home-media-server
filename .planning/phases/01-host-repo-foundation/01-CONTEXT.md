# Phase 1: Host & Repo Foundation -- Context

## Phase Goal
Create a GitOps repo skeleton and a Proxmox VM with a working Arc A380, the `/data` mount and Docker, ready to run stacks.

## Requirements Covered
- **R1 Repo foundation:** `compose.yaml` using `include:` with stacks/{edge,media,arr,download,transcode,ops}.yaml, `.env.example`, gitignored `secrets/`, pinned image tags, `scripts/mkdirs.sh`, docs skeleton. Spec sub-requirements R1.1–R1.8.
- **R2 Host & VM:** ZFS datasets (`tank/data` with recordsize=1M, `tank/backups`), IOMMU/vfio, Debian 13 VM (q35/OVMF) with appdata on SSD, Arc A380 passthrough with ReBAR (`vainfo` OK), `/data` via virtiofs, Docker Engine and the Compose plugin. Delivered as a runbook plus scripts. Spec sub-requirements R2.1–R2.6.

`.planning/REQUIREMENTS.md` does not exist. Full requirement detail lives in `.planning/PROJECT.md` and the spec.

## What Already Exists (from prior phases)
- None. This is the first phase of a greenfield repo.
- Present: `README.md` (1 line) and `.planning/` (PROJECT, ROADMAP, STATE, explorations design doc, and the Phase 1 spec).

## Key Design Decisions
- **Spec:** `.planning/specs/01-host-repo-foundation-spec.md` is authoritative for every contract. It covers script CLI, `common.sh` functions, `verify.sh` output, compose contract, file placement and failure modes. Critique verdict: PASS after 5 revisions.
- **Architecture approach: Hybrid.** Selected from three proposals: Minimal, Clean and Pragmatic.
  - Empty stack files (`services: {}`), each with a header naming the phase that will fill it.
  - Shared defaults in `stacks/_common.yaml` service `base`, pulled in with `extends:`. YAML anchors do not cross `include:` boundaries.
  - An external `proxy` network declared identically in every stack file.
  - Scripts split by where they run: `scripts/host/` (Proxmox) and `scripts/vm/` (guest). All host/VM scripts are dry-run by default and need `--apply`.
  - `scripts/vm/verify.sh` is the single acceptance check. `SKIP_HW=1` runs it in sandbox mode.
  - GitHub Actions CI lint.
- **Verified locally (Docker Compose v5.1.1):**
  - `extends: {file: _common.yaml}` inside included files works.
  - Identical duplicate external network declarations merge cleanly.
  - A `services: {}` file is valid.
  - Root `.env` is interpolated into included files.
- **Hardware boundary:** agents cannot reach the owner's Proxmox host. Plans verify scripts through dry-run output, `shellcheck` and sandbox runs. The real-hardware acceptance (`verify.sh` all PASS) is a `user_setup` checkpoint recorded in plan 01-04.
- **Waves:**
  - 01-01 (compose/env/docs) and 01-02 (lib + host scripts) share no files, so they run in parallel.
  - 01-03 needs `.env.example` (01-01) and `scripts/lib/common.sh` (01-02).
  - 01-04 validates everything, so it goes last.
- **Agents:**
  - Infrastructure work goes to engineering-infrastructure-devops.
  - Compose structure goes to engineering-senior-developer.
  - Runbook prose goes to product-technical-writer.
  - testing-qa-verification-specialist is on the first and last plans, because execution teams need a testing agent.
- **No `settings.json`,** so the default `max_tasks_per_plan = 3` applies.

## Plan Structure
- **Plan 01-01 (Wave 1)**: Compose skeleton & env contract. Builds `compose.yaml`, `_common.yaml`, 6 empty stacks, `.env.example`, `.gitignore`, `secrets/.gitkeep`, root README and the docs skeleton.
- **Plan 01-02 (Wave 1)**: Script library & Proxmox host scripts. Builds `scripts/lib/common.sh` and the three dry-run-by-default host scripts (ZFS, IOMMU/vfio, VM creation).
- **Plan 01-03 (Wave 2)**: Data tree, VM bootstrap & runbooks. Builds `scripts/mkdirs.sh`, `scripts/vm/00-bootstrap.sh`, and the host and VM runbooks with expected outputs.
- **Plan 01-04 (Wave 3)**: Verification & CI. Builds `scripts/vm/verify.sh`, the pinned-image checker, yamllint config and the GitHub Actions workflow, plus a full sandbox validation run.
