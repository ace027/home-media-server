# home-media-server — Roadmap

## Phases

- [x] Phase 1: Host & Repo Foundation (5 plans)
- [ ] Phase 2: Core Media Automation (4 plans)
- [ ] Phase 3: Edge & Secure Access (3 plans)
- [ ] Phase 4: Quality Automation & AV1 (3 plans)
- [ ] Phase 5: Observability & Resilience (3 plans)
- [ ] Phase 6: Family Onboarding & Launch (2 plans)

## Phase Details

### Phase 1: Host & Repo Foundation
**Goal**: Create a GitOps repo skeleton and a Proxmox VM with a working Arc A380, the `/data` mount and Docker, ready to run stacks.
**Requirements**: R1, R2
**Recommended Agents**: engineering-infrastructure-devops, engineering-senior-developer, testing-qa-verification-specialist
**Success Criteria**:
- [ ] `docker compose config` validates the `include:` tree with `.env.example` values; `secrets/` and `.env` are gitignored
- [ ] Every image in every stack file is pinned to an explicit tag
- [ ] The host runbook covers ZFS datasets, IOMMU/vfio, and VM creation (q35/OVMF, ReBAR where available) with A380 passthrough
- [ ] Inside the VM, `vainfo` on `/dev/dri/renderD128` lists AV1/HEVC/H.264 encode entrypoints
- [ ] `/data` is mounted via virtiofs, `scripts/mkdirs.sh` creates the TRaSH tree, and a hardlink test between `/data/usenet` and `/data/media` succeeds
**Plans**: 5 (01-01..01-04 in 3 waves, plus 01-05 for the migrated SSD pool)

### Phase 2: Core Media Automation
**Goal**: Complete the request → download → import → play loop on the LAN, with hardware transcoding.
**Requirements**: R3, R4, R5
**Recommended Agents**: engineering-infrastructure-devops, engineering-backend-architect, testing-api-tester, testing-qa-verification-specialist
**Success Criteria**:
- [ ] SABnzbd, Prowlarr, Sonarr, Sonarr-Anime, Sonarr-4K, Radarr, Radarr-4K, Lidarr, Plex, Seerr and Tautulli are all healthy (`docker compose ps`); Jellyfin is defined behind the `jellyfin` Compose profile and starts on demand (`docker compose --profile jellyfin up -d`)
- [ ] Prowlarr syncs its (Usenet-only) indexers to all 6 *arr instances (checked via API); the old torrent indexers and the qBittorrent/NZBGet download clients are removed
- [ ] A test request in Seerr (HD, 4K, anime) lands in the correct instance, root folder and SAB category, and is imported as a hardlink or atomic move (same inode)
- [ ] Plex shows hardware transcoding (hw) on a forced transcode; Jellyfin, when started for evaluation, does too
- [ ] Old app configs from `/tank/migration/old-docker-<date>.tar.zst` (archived from the old Ubuntu VM's `/docker`; Sonarr/Radarr/Plex/SAB) are migrated onto the same or newer image versions with paths remapped to `/data/...`, keeping settings, history and Plex watch state
- [ ] 4K titles mixed into `media/movies` and `media/tv` are identified and moved to `movies-4k`/`tv-4k` under Radarr-4K/Sonarr-4K
- [ ] The existing library migrated from the old SSD pool is adopted by Sonarr/Radarr/Lidarr (root folders under `/data/media`) with no re-downloads, and appears in Plex (and in Jellyfin when it is started)
**Plans**: 4 (spec: `.planning/specs/02-core-media-automation-spec.md`)

### Phase 3: Edge & Secure Access
**Goal**: Safe public access for Plex, Seerr and Authentik (plus Jellyfin only if it has been adopted), DDNS for the dynamic IP, and admin UIs reachable only through Twingate.
**Requirements**: R6, R7
**Recommended Agents**: engineering-infrastructure-devops, engineering-security-engineer, testing-qa-verification-specialist
**Success Criteria**:
- [ ] Changing the WAN IP (or forcing an update) causes cloudflare-ddns to update the DNS-only A records within 5 minutes
- [ ] Traefik serves valid Let's Encrypt wildcard certificates via DNS-01; ports 80 and 81 stay closed on the router
- [ ] An external scan shows only 443 and 32400 open; `*.int.<domain>` returns 403 from off-LAN without Twingate
- [ ] Over Twingate, every admin UI loads behind Authentik forward-auth, and admin MFA is enforced
- [ ] CrowdSec bans a simulated brute-force IP; the geo-block rejects a non-allowed country
- [ ] Plex remote access shows "Fully accessible"
- [ ] *(Only if Jellyfin is adopted after evaluation)* Jellyfin is routed through Traefik and OIDC login through Authentik works
**Plans**: 3

### Phase 4: Quality Automation & AV1
**Goal**: TRaSH-quality profiles, subtitles, cleanup, and off-peak AV1 conversion of all libraries without re-download loops.
**Requirements**: R8, R9
**Recommended Agents**: engineering-infrastructure-devops, testing-performance-benchmarker, testing-qa-verification-specialist
**Success Criteria**:
- [ ] `recyclarr sync` applies the HD, 4K and anime profiles; AV1 and DV custom-format scores are 0; DV without HDR10 fallback is scored strongly negative in the 4K profiles
- [ ] FileFlows encodes HD and 4K samples to AV1 on the A380 (QSV), within the 01:00-07:00 window with 1 runner
- [ ] 4K output is 10-bit with HDR10 mastering/MaxCLL metadata intact (checked with ffprobe/MediaInfo); DV profile 5 samples are skipped
- [ ] Output that isn't at least 15-20% smaller is rejected; after a replacement, Sonarr/Radarr rescan without flagging an upgrade or re-downloading
- [ ] Bazarr fetches subtitles for HD items; Maintainerr rules run in dry-run mode
**Plans**: 3

### Phase 5: Observability & Resilience
**Goal**: See problems quickly, get alerted, and prove the platform can be restored.
**Requirements**: R10, R11
**Recommended Agents**: engineering-infrastructure-devops, testing-qa-verification-specialist, product-technical-writer
**Success Criteria**:
- [ ] Homepage shows every service through Twingate; Uptime Kuma monitors all public and internal endpoints
- [ ] Discord/Notifiarr alerts fire for a test download, a failed monitor and a Diun image update
- [ ] Nightly vzdump to PBS and Backrest/restic of appdata to the off-site target both complete successfully
- [ ] Sanoid snapshots, ZFS scrub and SMART alerting are active on the host
- [ ] A restore drill (VM from PBS plus appdata from restic) succeeds and is documented in `docs/runbooks/`
**Plans**: 3

### Phase 6: Family Onboarding & Launch
**Goal**: Family members are invited, sharing rules are set, and the guide gets them watching with no admin help.
**Requirements**: R12
**Recommended Agents**: product-technical-writer, engineering-security-engineer, testing-qa-verification-specialist
**Success Criteria**:
- [ ] Authentik invite flow creates a family account; every family member gets all Plex libraries, including Movies 4K and TV 4K (non-4K devices transcode)
- [ ] The one-page family guide covers installing Plex, signing in, requesting in Seerr, and recommended AV1-capable devices (Jellyfin is covered only if it has replaced Plex)
- [ ] One family member completes request → remote watch end-to-end with no admin action (HD)
- [ ] An exposure review confirms no admin UI is reachable publicly and all secrets are absent from git history
**Plans**: 2

## Progress

| Phase | Plans | Completed | Status |
|-------|-------|-----------|--------|
| 1. Host & Repo Foundation | 5 | 5 | Complete |
| 2. Core Media Automation | 4 | 3 | In progress |
| 3. Edge & Secure Access | 3 | 0 | Not started |
| 4. Quality Automation & AV1 | 3 | 0 | Not started |
| 5. Observability & Resilience | 3 | 0 | Not started |
| 6. Family Onboarding & Launch | 2 | 0 | Not started |
