# Phase 0 - Clean Release Baseline

Status: complete. The dependency, offline-security, and toolchain changes were
kept in separate pull requests, independently verified, and merged into
protected `handover-ready`.

## Merge evidence

1. Dependency maintenance PR
   [#1](https://github.com/Mohamad-H-Hallal/Thesis/pull/1) merged as
   `4f309473bc3847e89c0d2ad8b87baa1909163d4a`.
2. The later `brace-expansion` advisory was isolated in PR
   [#2](https://github.com/Mohamad-H-Hallal/Thesis/pull/2) and merged as
   `190309e6611a2aa67ef14d912cd2b360bad48229`.
3. Offline isolation and security PR
   [#3](https://github.com/Mohamad-H-Hallal/Thesis/pull/3) merged as
   `2af1090e7cbe83f46e9e3a041c59297fab1c6c48`.
4. Reproducible toolchain PR
   [#4](https://github.com/Mohamad-H-Hallal/Thesis/pull/4) merged as
   `b85e573e8f06213f5e1f66c8dd7f681a528b1112`.

The annotated tag `preprod-baseline-2026-07-27` points to the Phase 0 merge
commit `b85e573e8f06213f5e1f66c8dd7f681a528b1112`. The tag is historical
evidence and must not be moved as later phases advance `handover-ready`.

## Current branch policy

`handover-ready` is the public repository's default branch and is protected:

- required checks must be current with the branch before merge;
- administrator enforcement is enabled;
- force pushes and branch deletion are disabled;
- pull-request conversations must be resolved;
- stale reviews are dismissed.

Phase 6 adds independent CodeQL, complete-history secret scanning, recursive
dependency scanning, and release-image scanning. Their check contexts must be
added to the protected branch after their first successful run so that future
pull requests cannot bypass them.

## Gate interpretation

Phase 0 established a clean code baseline; it was not a deployment approval.
Current dependency audits and release scans are rerun in Phase 6 and again for
each release candidate. Availability of newer incompatible dependency majors
is informational and does not justify an unreviewed upgrade.

The locally installed Flutter SDK reports the pinned Flutter 3.41.2 and Dart
3.11.0 versions, but its launcher has a machine-local repair. Release
provenance must come from clean CI and immutable Phase 7 artifacts rather than
that modified local SDK directory.
