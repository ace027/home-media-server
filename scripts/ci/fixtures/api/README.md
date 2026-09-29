# API test fixtures

Synthetic JSON responses served by the stub `curl` from
`scripts/ci/make-api-stubs.sh`. They were written by hand from the documented
response shapes of SABnzbd, Sonarr, Radarr, Lidarr and Prowlarr. They are
**not** real API output, and real API output must never be pasted in here.

Layout: `<set>/<svc>/<METHOD>_<path+query>.json`. In the name, `/ ? & = .`
become `_`, runs of `_` collapse to one, and a trailing `_` is dropped. For
example, `GET /api/v3/rootfolder` is `GET_api_v3_rootfolder.json`, and SAB's
`GET /api?mode=queue&output=json` is `GET_api_mode_queue_output_json.json`.
A `.json.1`, `.json.2` … file is the response to the 2nd, 3rd … call of the
same request.

- `initial/`: the state right after the restore.
  - Old roots `/data/{shows,anime,movies}/` hold the items, and unmonitor-deleted
    is on. The `.1` variants give the re-GET after the editor call.
  - qBittorrent clients, and a SABnzbd client with the old category.
  - Torrent indexers and a remote path mapping.
  - Prowlarr has a torrent indexer, FlareSolverr, NZBGet, an old
    `animesonarr` app and a `Sonarr` app with `syncLevel: disabled`.
  - SABnzbd has the old dirs and categories. Its queue is unpaused, and the
    `.1` variant is paused, for the resume at the end of a full run.
- `converged/`: the state after a full wiring. The wire and remap scripts must
  make 0 mutating calls against it. `@HOSTNAME@` in the SAB `host_whitelist`
  is replaced with `hostname -s` by the test.

Every privacy field (`apiKey`, `password`) is masked as `"********"`, the way
real GET responses return it. That is the idempotency case for `same_state`.
The only API key used anywhere is the dummy
`0123456789abcdef0123456789abcdef`. The test writes it into `config.xml` and
`sabnzbd.ini` under a temp `APPDATA_ROOT`, so it never appears in this
directory. CI greps `scripts/ci/fixtures/` for 32-hex strings.
