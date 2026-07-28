# AGENTS.md

Operating instructions for coding agents working in DapNext. Read this file before every task.

Read `CONTEXT.md` before changing code. It contains the current product surface, ownership boundaries, domain contracts, algorithms, and known gaps. The repository is the final source of truth when documentation and code disagree.

Task-specific user instructions override this file.

---

## 0. Non-negotiables

1. **Never fabricate.** Do not invent files, APIs, commands, test results, runtime behavior, or listening results.
2. **Touch only what the task requires.** Every changed line must trace directly to the request.
3. **Preserve user work.** Never discard or rewrite unrelated modified or untracked files.
4. **Use the existing source of truth.** Do not create parallel state, storage, rendering, navigation, or playback ownership.
5. **Do not perform Git operations, slow validation, dependency changes, or speculative architecture without explicit approval.**

---

## 1. Before writing code

For non-trivial work, state the intended change and validation in one or two sentences.

Before editing:

1. Read `CONTEXT.md`.
2. Run `git status --short`.
3. Inspect the smallest set of files that owns the behavior.
4. Inspect relevant callers and data flow.
5. Identify the existing source of truth.
6. Define a concrete success condition.

Resolve ambiguity from the repository before asking the user. Match existing patterns even when a different greenfield design would also be reasonable.

---

## 2. Simplicity first

- Prefer a local fix over a refactor.
- Refactor only when the current structure blocks the requested behavior.
- Do not add unrequested features, configurability, hooks, or future-facing infrastructure.
- Reuse existing domain types and services.
- Prefer concrete implementations over single-implementation protocols.
- Prefer private helpers and local subviews before adding files.
- Add a file only for a real feature boundary or clear locality benefit.
- Do not split a file solely because it is large.
- Handle failures that can actually occur; do not design around impossible states.

Use the simplest implementation that satisfies the verified requirement.

---

## 3. Surgical changes

- Do not redesign adjacent flows.
- Do not perform opportunistic renames, formatting sweeps, or unrelated cleanup.
- Do not move files to satisfy an idealized architecture.
- Do not remove pre-existing dead code unless requested.
- Remove only code made obsolete by your own change.
- Match existing naming, formatting, access control, and file layout.
- Keep diffs directly reviewable.

Before finishing, inspect every changed line and revert anything unrelated to the request.

---

## 4. Goal-driven execution

Translate the request into verifiable behavior before editing.

- Logic change: inspect the relevant call paths and invariants.
- Bug fix: reproduce from available evidence when practical.
- UI change: compare the implementation with the supplied design or specification.
- Performance change: measure before and after when profiling is requested.
- Audio change: separate code validation from listening validation.

Do not weaken a valid check to make an implementation appear successful.

---

## 5. Validation policy

Dap uses an intentionally lightweight default workflow.

Unless explicitly requested, do **not** run Xcode builds, tests, simulators, previews, profiling, screenshot automation, or audio listening validation.

Default validation:

1. inspect the edited code;
2. inspect `git diff`;
3. run `git diff --check` when useful;
4. inspect `git status --short`;
5. inspect `project.pbxproj` when files or resources changed.

Never claim that code compiles, runs, renders correctly, performs better, or sounds correct unless that validation actually ran.

---

## 6. Git policy

Do not commit, amend, merge, rebase, push, create or delete branches, stash, reset, restore, or alter history unless explicitly requested.

When a Git operation is requested:

- inspect repository status first;
- preserve unrelated changes;
- limit the operation to the requested scope;
- use a descriptive commit subject under 72 characters;
- do not add AI co-author attribution unless requested.

When editing `project.pbxproj`, make the smallest manual change and inspect its diff carefully.

---

## 7. Communication

- Start with the answer, decision, or action.
- State when a premise conflicts with the repository.
- Separate verified facts, inferences, assumptions, and unverified risks.
- Do not present plausible-looking code as verified.
- Keep progress updates concise.
- In the final report, state exactly what changed and what did not run.

---

## 8. When to ask and when to proceed

Ask before editing only when:

- materially different interpretations remain after repository inspection;
- the request conflicts with a load-bearing contract or migration path;
- required credentials, devices, or external resources are unavailable;
- the literal request conflicts with the stated goal.

Proceed when the task is reversible, the repository resolves the ambiguity, or the user already answered the question.

Do not silently choose between materially different product behaviors.

---

## 9. Self-improvement

Keep this file as durable operating guidance, not a project encyclopedia.

When the user corrects an agent mistake:

1. decide whether an existing rule was ignored or a rule is missing;
2. tighten an existing rule before adding another;
3. add one concrete line to section 11 only for a recurring failure;
4. remove obsolete learnings when the project changes.

Do not add feature specifications, exact UI geometry, audio topology, algorithm constants, or transient implementation details here. Put them in `CONTEXT.md` or a focused specification.

---

## 10. Project context

### Product

Dap is a native iOS app that turns captured or imported images into deterministic Musical Photos and combines them in a lightweight Jam.

Optimize for clear product behavior, distinctive visual and sonic character, native iOS interaction, small reversible changes, low maintenance, and fast iteration by a small team.

Do not optimize for hypothetical scale, enterprise layering, or feature systems that do not exist.

### Stack

- Swift 6 and SwiftUI
- Observation with `@Observable`
- iOS 26.0+
- AVFoundation and AVAudioEngine
- PhotosUI, Vision, Core Graphics, and UIKit where required
- Foundation Models for optional generative metadata
- Metal for the Capture lava-lamp shader
- local JSON and PNG persistence in Application Support
- no third-party packages
- one application target; no test target currently documented

Reverify these facts against the repository when they affect a task.

### Commands

- Install: none currently documented
- Build: `TODO — confirm the current project and scheme before running xcodebuild`
- Test: not currently configured; do not invent a command
- Lint: not currently configured
- Typecheck: performed by an Xcode build when requested
- Run locally: `TODO — confirm the active Xcode scheme and device`

Do not add tooling merely to replace a `TODO`.

### Tooling

- `rtk` is installed and approved for this repository. It compresses shell command output before it reaches the agent's context.
- Prefix git, build, and search commands with `rtk` when your environment does not already auto-rewrite them (e.g. `rtk git status --short`, `rtk git diff --stat`).
- If `rtk` is not available, or a command fails through it, fall back to the plain command. Do not treat this as a task blocker.
- Do not install, reconfigure, upgrade, or extend `rtk` without explicit approval.

### Layout

- Application source: `Dap/`
- Project configuration: `DapNext.xcodeproj/`
- Entry and root presentation: `Dap/App/`
- Feature UI: `Dap/Features/`
- Domain models: `Dap/Models/`
- Shared services: `Dap/Services/`
- Resources: `Dap/Resources/` and `Dap/Assets.xcassets`
- Tests: no current test directory documented

Use the repository tree over this summary when they differ.

### Ownership boundaries

- `AppRootView`: application-level presentation and root navigation.
- `PhotoLibraryViewModel`: shared library state and playback coordination.
- `PhotoStore`: persisted library I/O.
- `PhotoMusicPipeline`: deterministic image-to-music conversion.
- `RetroCoverRenderer`: canonical pitch palettes and Cover rendering.
- `PhotoMetadataGenerator`: optional metadata enrichment.
- `MusicPlayer`: audio graph, rendering, scheduling, and playback.
- `CameraController`: capture-session and camera hardware behavior.
- `JamView`: Jam-local interaction and transport intent.
- Jam builders and libraries: deterministic arrangement, role, and groove logic.

Read `CONTEXT.md` and the implementation for detailed current contracts. Do not duplicate volatile feature internals here.

### State and concurrency

- Every mutable state value has one clear owner.
- Use `@State` for local interaction, `@Binding` for parent-owned mutation, and `@Observable` for shared feature state.
- Prefer derived values over mirrored state.
- UI-facing mutable state stays on `@MainActor`.
- Persistence stays inside the `PhotoStore` actor.
- Heavy image processing, Vision work, and audio rendering stay off-main.
- Do not perform disk I/O, bundle decoding, or full-resolution image decoding in a SwiftUI `body`.
- Guard asynchronous results against stale completion.
- Do not use `@unchecked Sendable` without explicit safety reasoning.

### Product and design conventions

- The current user specification and Figma direction are the visual source of truth.
- Preserve existing components when visual details are unspecified.
- Prefer native SwiftUI navigation and presentation.
- Do not introduce coordinators, routers, or flow frameworks.
- Do not add unrequested visual effects, haptics, animation, gestures, labels, or decorative chrome.
- Animation must explain state change, continuity, or direct feedback.
- Respect Reduce Motion and native accessibility semantics.
- Keep deterministic musical and visual behavior stable for the same stable inputs.
- Use canonical domain mappings instead of duplicate note, color, role, or resource tables.
- Foundation Models may enrich optional metadata but must not replace deterministic creation, persistence, arrangement, or playback.

### Forbidden without explicit approval

- third-party dependencies;
- duplicate state, cache, persistence, or playback owners;
- coordinators, routers, repositories, use-case layers, or orchestrators;
- generic plugin, effects, processing, or audio frameworks;
- speculative persistence models or migrations;
- Core Data, SwiftData, or CloudKit;
- unconstrained runtime randomness for deterministic behavior;
- Foundation Models for deterministic musical algorithms;
- broad rewrites for local bugs;
- automatic Git operations;
- new tests, targets, build pipelines, or developer tooling;
- transient feature documentation in this file.

### Completion report

At the end of an implementation task, report:

1. files changed;
2. behavior implemented;
3. important architectural, product, or musical decisions;
4. validation actually performed;
5. unresolved assumptions and risks;
6. whether build, tests, simulator, profiling, listening validation, commit, and push were not performed.

---

## 11. Project Learnings

- (empty)
