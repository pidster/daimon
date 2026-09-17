# ADR 0002: macOS 27 is the platform baseline

Date: 2026-09-17. Status: accepted.

## Context

`FoundationModels` first shipped in macOS 26, so the framework alone would allow a lower floor. The project
owner set macOS 27 as the baseline, and the development and test machine runs 27.0.

## Decision

The SwiftPM platform is `.macOS("27.0")`. It is written as a string because `PackageDescription` in Xcode 27.0
has no `.v27` case. Do not lower the floor for compatibility.

## Consequences

- Any macOS 27 API can be used without availability checks.
- CI must run on a macOS 27 image. None is provisioned yet, so the workflow is manual-only for now.
