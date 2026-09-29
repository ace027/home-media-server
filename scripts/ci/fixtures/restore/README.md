# Restore test fixtures

`scripts/ci/test-restore.sh` generates everything it needs at test time
under a `mktemp -d` directory. Nothing binary is committed here:

- a fake old `/docker` tree (Plex, Seerr, Tautulli, Sonarr, animesonarr,
  Radarr, Lidarr, Prowlarr, SABnzbd, plus nzbget, bazarr, logs, caches and
  backups that must *not* be restored), with small SQLite databases built
  by `sqlite3`;
- the archive `old-docker-2026-09-27.tar.zst` made from that tree;
- stub `ssh`, `docker` and `setpriv` executables.

All of it is **synthetic**. The only API key used is the dummy
`0123456789abcdef0123456789abcdef`, the Seerr key is the dummy base64
`ZHVtbXlrZXlkdW1teWtleQ==` and the Plex token is `dummytoken0123456789`.
Never copy real config, databases or keys from the migration archive into
this directory; CI greps `scripts/ci/fixtures/` for 32-hex strings.
