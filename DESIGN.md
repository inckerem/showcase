# Showcase KCS design notes

## Story

A driver has an older jailbroken iPad and wants wireless CarPlay without
replacing the vehicle's original head unit. The KCS edition explains how to
use an existing portable Wi-Fi router when the iPad cannot create a hotspot.

## Visual system

- The KCS site supplies the blue `#3b82f6` and purple `#8b5cf6` palette.
- The public `kcs.net.tr` homepage is outside this project and must not be
  changed. The `/repo/` landing page was restored to its previous design at
  Kerem's request on 2026-11-07; package depictions retain KCS branding.
- The iOS app keeps Showcase's established black CarPlay surface and uses KCS
  blue for primary controls. Its display name and About page identify KCS and
  credit Amine Rostane for the original work.

## Decisions · 2026-11-07

- Kerem requested a KCS maintained public fork, KCS package design and
  telemetry destination, while keeping the original developer credited.
- Usage sharing defaults off in the KCS edition and creates a fresh ID when
  enabled. Diagnostics are uploaded only after explicit confirmation.
- Current public package is rootful. Rootless and Taurine source/build templates
  remain in the repository, but their packages are not advertised as available.
- The previously unsafe `autopower/` prototype remains unpublished. The
  vehicle power daemon source is in `autopower-v3/`.
- Kerem then clarified that the original `kcs.net.tr` site must remain as it
  was. The `/repo/` index was restored byte-for-byte from the pre-change
  backup; the package repository and app remain available.
