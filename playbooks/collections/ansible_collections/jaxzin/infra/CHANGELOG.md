# Changelog

# [1.6.0](https://github.com/jaxzin/ansible-collection-infra/compare/1.5.0...1.6.0) (2026-06-17)


### Features

* **tailscale_sidecar:** add opt-in userspace networking mode ([#10](https://github.com/jaxzin/ansible-collection-infra/issues/10)) ([d361f54](https://github.com/jaxzin/ansible-collection-infra/commit/d361f54898e418f416411b8d9b7f946f6a7a6593))

# [1.5.0](https://github.com/jaxzin/ansible-collection-infra/compare/1.4.0...1.5.0) (2026-06-17)


### Features

* **tailscale_sidecar:** fail fast on expired/revoked auth key ([#9](https://github.com/jaxzin/ansible-collection-infra/issues/9)) ([2cfd8cc](https://github.com/jaxzin/ansible-collection-infra/commit/2cfd8cc079df560f6b226ac06502ed3f6cdfd146))

# [1.4.0](https://github.com/jaxzin/ansible-collection-infra/compare/1.3.0...1.4.0) (2026-06-17)


### Features

* **tailscale_sidecar:** self-heal DNS so tailscaled's empty DefaultResolvers can't break the netns ([#8](https://github.com/jaxzin/ansible-collection-infra/issues/8)) ([3c86b42](https://github.com/jaxzin/ansible-collection-infra/commit/3c86b42fb6148cc65586c270a3d81a545dc1cc4b)), closes [#7](https://github.com/jaxzin/ansible-collection-infra/issues/7)

# [1.3.0](https://github.com/jaxzin/ansible-collection-infra/compare/1.2.0...1.3.0) (2026-06-16)


### Bug Fixes

* require ansible-core >=2.15 (drop EOL ansible-core 2.14) ([84691fe](https://github.com/jaxzin/ansible-collection-infra/commit/84691fee79cea0e4557de4cd1a33e4a1bb428ac0))


### Features

* declare community.docker (>=3.0.0) runtime dependency ([b39a3dc](https://github.com/jaxzin/ansible-collection-infra/commit/b39a3dc29aaea2f4457d45f1b8db62e2afd8f44f))

## [1.2.0] - 2026-06-15

### Added

- `tailscale_sidecar`: configurable `tailscale_log_driver` /
  `tailscale_log_options` (default `json-file`) so the sidecar avoids the
  Synology ContainerManager `db` log driver, which wedges and breaks
  healthcheck execs and container restarts.

## [1.1.0] - 2026-05-05

### Added

- `tailscale_sidecar`: configurable container memory limits
  (`tailscale_memory_limit` / `tailscale_memory_swap`).
- `tailscale_sidecar`: configurable `TS_ACCEPT_DNS` via `tailscale_accept_dns`,
  for sidecars that must resolve other containers via Docker's embedded DNS.

## [1.0.0] - 2026-02-25

### Added

- Initial release of the `jaxzin.infra` collection with the `tailscale_sidecar`
  role: deploys a Tailscale sidecar container with an optional Tailscale Serve
  HTTPS reverse proxy.
