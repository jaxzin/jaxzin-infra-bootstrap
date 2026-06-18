# Spec: Automated releases via semantic-release

**Date:** 2026-06-15
**Status:** Approved

## Goal

Merges to `main` automatically cut a new release of the `jaxzin.infra` collection
based on Conventional Commit messages: version is derived, `galaxy.yml` and
`CHANGELOG.md` are updated, the collection is built and published to Ansible
Galaxy, a git tag + GitHub Release are created, and the version bump is committed
back to `main`.

## Decisions

- **Tool:** JS `semantic-release` (Node), config in `.releaserc.json`.
- **Scope:** full pipeline including `ansible-galaxy collection publish`.
- **Tag format:** `${version}` — **no leading `v`** — to match the existing
  `1.0.0`/`1.1.0`/`1.2.0` tags so `1.2.0` is recognized as the last release.
  The duplicate `v*` tags don't match the format and are ignored.
- **Initial release:** a `feat:` commit after merge ships the already-merged
  `community.docker` / `requires_ansible` changes as `1.3.0`.

## Versioning rules (Conventional Commits → SemVer)

- `fix:` → patch, `feat:` → minor, `feat!:` / `BREAKING CHANGE:` → major.
- `ci:`, `chore:`, `docs:`, `test:`, `refactor:` → no release.

## Components

| File | Responsibility |
| --- | --- |
| `.github/workflows/release.yml` | Runs on `push: [main]` (+ manual `workflow_dispatch` dry-run). Sets up Node + uv/ansible, runs `npx semantic-release`. |
| `.releaserc.json` | Plugin pipeline: commit-analyzer → release-notes-generator → changelog → exec (build+publish) → git (commit back) → github (tag+release). |
| `package.json` + `package-lock.json` | Pin semantic-release + plugins; installed with `npm ci`. |
| `scripts/release-prepare.sh` | Sets `galaxy.yml` version to the next version and builds the collection tarball. Kept as a script so it is testable in isolation. |
| `galaxy.yml` (`build_ignore`) | Excludes all release machinery from the published tarball. |
| `CHANGELOG.md` | Reduced to title + version history so semantic-release owns it going forward. |

## Data flow (a releasing merge to main)

1. `commit-analyzer` reads commits since the last `${version}` tag → next version.
2. `release-notes-generator` builds notes.
3. `changelog` writes notes into `CHANGELOG.md` (title preserved).
4. `exec.prepareCmd` = `scripts/release-prepare.sh <version>` → bump `galaxy.yml`, build tarball.
5. `exec.publishCmd` → `ansible-galaxy collection publish … --api-key $GALAXY_API_KEY`.
6. `git` commits `galaxy.yml` + `CHANGELOG.md` back to `main` with `[skip ci]` (breaks the re-trigger loop).
7. `github` creates the tag + GitHub Release (and attaches the tarball).

## Prerequisites / operator notes

- `GALAXY_API_KEY` repo secret must be set (galaxy.ansible.com API key).
- `main` is unprotected, so the bot pushes the bump with the default `GITHUB_TOKEN`.
- Conventional commits are load-bearing → use squash-merge with conventional PR titles.

## Out of scope (YAGNI)

Signed bot commits (no repo rule requires them), pre-release channels, PR-title linting.
