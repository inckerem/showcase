# Showcase KCS design notes

## Story

A driver has an older jailbroken iPad and wants wireless CarPlay without
replacing the vehicle's original head unit. The repository page should let
them copy the Cydia source immediately, then show how to use an existing
portable Wi-Fi router when the iPad cannot create a hotspot.

## Visual system

- The KCS site supplies the blue `#3b82f6`, purple `#8b5cf6`, pale blue,
  lavender and pink background palette. The repo page uses those values.
- The phone, router and iPad drawing shows the actual shared network path.
- The primary action is copying `https://kcs.net.tr/repo/`.
- The iOS app keeps Showcase's established black CarPlay surface and uses KCS
  blue for primary controls. Its display name and About page identify KCS and
  credit Amine Rostane for the original work.

## Decisions · 2026-11-07

- Kerem requested a KCS maintained public fork, KCS repository design and
  telemetry destination, while keeping the original developer credited.
- Usage sharing defaults off in the KCS edition and creates a fresh ID when
  enabled. Diagnostics are uploaded only after explicit confirmation.
- Current public package is rootful. Rootless and Taurine source/build templates
  remain in the repository, but their packages are not advertised as available.
- The previously unsafe `autopower/` prototype remains unpublished. The
  vehicle power daemon source is in `autopower-v3/`.

## Clarification · 2026-11-07

The public `https://kcs.net.tr/` homepage is separate from the package repository. It was not changed. Kerem confirmed that the KCS design may be used for `/repo/`; only that subpath is deployed by this project.
