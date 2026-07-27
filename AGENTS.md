# AGENTS.md

## Purpose

This file defines how coding agents should work inside DapNext.

Read `CONTEXT.md` before changing code. It records the current product surface, domain language, module ownership, deterministic algorithms, audio contracts, and known gaps. The repository remains the final source of truth whenever documentation and code disagree.

Task-specific user instructions take precedence over this file.

## Product posture

Dap is an experimental iOS app that turns captured or imported images into deterministic Musical Photos and combines up to three of them in a lightweight Jam.

Optimize for:

- clear product behavior;
- distinctive visual and sonic character;
- small, reversible changes;
- native iOS behavior;
- low maintenance cost;
- fast iteration by a small team.

Do not optimize for hypothetical scale, enterprise layering, or feature systems that do not exist yet.

## Technical baseline

- iOS 26.0+
- Swift 6
- SwiftUI
- Observation with `@Observable`
- AVFoundation and AVAudioEngine
- AVFoundation camera APIs
- PhotosUI
- Vision
- Foundation Models
- Core Graphics and UIKit image primitives where required
- Metal shader for the Capture lava lamp
- local JSON and PNG persistence in Application Support
- bundled WAV resources for Jam melodic voices and percussion
- no third-party dependencies
- one application target
- no test target in the current project

Do not add a dependency without explicit approval.

## Default working method

1. Read `CONTEXT.md`.
2. Check `git status --short` before editing.
3. Inspect the smallest set of files that owns the requested behavior.
4. Identify the existing source of truth for state, navigation, persistence, image processing, arrangement, or audio rendering.
5. Make the smallest coherent change.
6. Inspect the final diff and repository status.
7. Report exactly what changed, what was preserved, what validation ran, and what risk remains.

Prefer a local fix over a refactor. Refactor only when the current structure directly prevents the requested behavior.

## Validation policy

Do not run builds, tests, Xcode, simulators, previews, profiling, or other slow validation unless the user explicitly requests it.

Default validation is:

- inspect the edited code;
- inspect `git diff`;
- run `git diff --check` when useful;
- inspect `git status --short`;
- inspect `project.pbxproj` only when files or resources were added, removed, renamed, or moved.

Do not create a test target or add tests unless explicitly requested.

Never claim that code compiles, runs, or sounds correct when the corresponding build, runtime check, or listening test was not performed.

## Git policy

Do not commit, amend, merge, rebase, push, create a branch, delete a branch, or alter Git history unless explicitly requested.

Never discard unrelated user changes. Preserve modified and untracked files outside the task scope.

When editing `project.pbxproj`, make the smallest manual change and inspect the diff carefully.

## Change discipline

- Preserve existing behavior unless the task explicitly changes it.
- Do not redesign adjacent flows while implementing a local request.
- Do not add speculative infrastructure for future features.
- Avoid opportunistic renames, formatting sweeps, and unrelated cleanup.
- Do not move files merely to satisfy an idealized architecture.
- Keep diffs reviewable.
- Reuse existing domain types and services before creating new ones.
- Prefer concrete implementations over protocols created only for dependency injection.
- Prefer private helpers or local subviews before adding files.
- Add a file only when it creates a real feature boundary or materially improves locality.
- Do not split large files solely because they are large.

## Current source tree and ownership

```text
Dap/
├── App/
│   ├── DapApp.swift
│   └── AppRootView.swift
├── Features/
│   ├── Capture/
│   │   ├── CameraView.swift
│   │   └── DapLavaLamp.metal
│   ├── Gallery/
│   │   ├── GalleryView.swift
│   │   ├── PhotoInspectorView.swift
│   │   └── PhotoLibraryViewModel.swift
│   └── Jam/
│       ├── JamView.swift
│       ├── JamArrangementBuilder.swift
│       └── JamGrooveLibrary.swift
├── Models/
│   └── PhotoSound.swift
├── Services/
│   ├── DrumSampleLibrary.swift
│   ├── MelodicSampleLibrary.swift
│   ├── MusicPlayer.swift
│   ├── PhotoMetadataGenerator.swift
│   ├── PhotoMusicPipeline.swift
│   ├── PhotoStore.swift
│   └── RetroCoverRenderer.swift
├── Resources/
│   └── Audio/
│       ├── DapAnalogFamily/
│       └── Drums/
├── Assets.xcassets
└── Info.plist
```

### `AppRootView`

Owns application-level presentation only:

- Gallery/Jam section selection;
- Gallery navigation path;
- Capture presentation;
- root chrome;
- the single shared `PhotoLibraryViewModel` lifetime.

Do not move processing, persistence, camera, arrangement, or audio rendering into this view.

### `PhotoLibraryViewModel`

This is the shared application state for Gallery, Capture, Inspector, and Jam. It owns:

- loaded `PhotoSound` items;
- in-memory Cover PNG data;
- single and batch import state;
- progressive metadata tasks;
- the single `MusicPlayer` instance;
- single-photo and transient Jam playback coordination;
- the callback that informs Jam when a replacement loop has been scheduled.

Do not create another library owner, Cover cache, or playback engine.

### `PhotoStore`

Owns all persisted library I/O. It is an actor and serializes saves and metadata updates.

Callers must not reproduce its read-modify-write logic or access Cover files directly from SwiftUI views.

### `PhotoMusicPipeline`

Owns deterministic conversion from Source Image data to:

- normalized image data in memory;
- visual analysis;
- musical sequence;
- tonal identity;
- generated pattern-halftone Cover.

Keep this work outside SwiftUI `body` evaluation and off the main actor.

### `RetroCoverRenderer`

Owns:

- canonical pitch colors;
- four-tone palettes;
- clustered-dot pattern-halftone rendering;
- legacy Floyd-Steinberg rendering used for tone analysis;
- low-level pixel operations.

Do not duplicate palette or pitch-color mappings elsewhere.

### `PhotoMetadataGenerator`

Owns best-effort metadata enrichment using Vision and Foundation Models.

Metadata generation must remain optional. Failure must not invalidate a successfully persisted Musical Photo.

### `MusicPlayer`

Owns:

- the single AVAudioEngine graph;
- offline stereo rendering;
- playback scheduling and interruption handling;
- one-shot and native looping playback;
- debounced latest-wins loop replacement with `.interruptsAtLoop`;
- procedural Gallery/Inspector synthesis;
- procedural Future Bass rendering;
- sample-based Harmony and Melody rendering;
- sampled percussion rendering and procedural fallbacks;
- kick-driven ducking for Bass and Harmony;
- final output clamping.

Views and builders may provide musical values, but they must not construct an audio graph, load samples, or render audio.

### `MelodicSampleLibrary`

Owns bundled Dap Analog Family sample lookup, octave wrapping, nearest-root selection, and sample loading.

Do not perform bundle lookup or sample decoding in SwiftUI or `JamArrangementBuilder`.

### `DrumSampleLibrary`

Owns bundled drum sample loading and the concrete Soft, Club, Break, and Metal kit mappings and trims.

Do not duplicate sample paths, kit composition, or trim values in UI code.

### `CameraView` and `CameraController`

`CameraView` owns Capture presentation and user-facing state. `CameraController` owns AVCaptureSession configuration, rotation, mirroring, flash capability, zoom, camera switching, capture, and live pitch-color sampling.

Do not split `CameraController` simply because the file is large. Split only when a real independent interface appears.

### `GalleryView` and `PhotoInspectorView`

Gallery owns browsing and UUID navigation. Inspector owns presentation and playback actions for one existing Musical Photo.

Neither view owns persistence, image processing, metadata generation, arrangement, or audio rendering.

### Jam modules

- `JamView` owns local selection, Vibe position, manual/Auto Drum Kit selection, visible transport, pending-state feedback, and Jam playback intent.
- `JamArrangementBuilder` owns deterministic role assignment, global harmony, Vibe interpolation, Bass/Harmony transformations, and the Melody Motif Engine.
- `JamGrooveLibrary` owns Jam-region classification, stable groove-variant selection, and the twelve hard-coded percussion patterns.

Keep these boundaries intact unless a requested behavior proves they are wrong.

## State-management rules

Every state value needs one clear owner.

Use:

- `@State` for local presentation and interaction state;
- `@Binding` for child mutation of parent-owned state;
- `@Observable` for shared mutable feature state;
- derived properties instead of mirrored state;
- stable UUIDs at feature boundaries.

Avoid:

- duplicated playback state;
- copied library arrays as independent truth;
- synchronization chains built from multiple `onChange` handlers;
- global singletons for UI state;
- additional environment objects when direct injection already works.

Jam selection, Vibe position, Drum Kit selection, transport, and pending feedback remain local to `JamView` until Jam persistence is explicitly specified.

## Navigation rules

Use native SwiftUI navigation and presentation:

- `NavigationStack`;
- typed values in navigation paths;
- `.sheet`;
- `.fullScreenCover`;
- native toolbar items;
- the current Gallery/Jam section switcher.

Do not introduce coordinators, routers, route protocols, navigation services, or an application flow state machine.

Preserve these contracts unless explicitly changed:

- Gallery and Jam are root sections.
- Capture is presented full-screen from the Gallery root.
- Photo Inspector is reached through the Gallery UUID path.
- Root chrome is hidden while Inspector is pushed.
- Leaving Jam stops transient Jam playback.

## SwiftUI and design rules

The requested design and existing Figma direction are the visual source of truth.

Do not add unrequested:

- gradients;
- glass;
- blur;
- shadows;
- haptics;
- animations;
- labels;
- navigation controls;
- decorative backgrounds;
- custom gestures.

When a visual detail is unspecified, preserve the existing component or use the simplest native treatment.

Extract a subview when it represents a meaningful component, owns independent behavior, is reused, or substantially improves readability. Do not create many tiny files solely to reduce line count.

Avoid `AnyView`, preference keys, custom layout systems, and type erasure unless the requirement demands them.

Use UIKit only where SwiftUI does not adequately expose the required platform behavior.

## Interaction and animation rules

Animation must explain a state transition, preserve continuity, or provide direct feedback.

- Respect Reduce Motion.
- Keep durations short and interactions responsive.
- Avoid delayed state changes used as layout fixes.
- Keep one owner for animation state.
- Preserve the Gallery-to-Inspector zoom transition unless explicitly changed.
- Preserve Jam's next-loop application contract for updates made during playback.
- Preserve the `Next bar` pending feedback semantics for Drum Kit changes.

Haptics should mark meaningful discrete boundaries, not continuous Vibe movement.

## Accessibility

Interactive controls must have usable labels and adequate hit targets.

Preserve or add:

- VoiceOver labels and values;
- selected and disabled states;
- Reduce Motion behavior;
- logical focus order;
- native control semantics where possible.

Do not create a parallel accessibility-only interface.

## Concurrency and performance

- UI-facing mutable state stays on `@MainActor`.
- Persistence stays inside the `PhotoStore` actor.
- Heavy image processing, Vision work, and audio rendering stay off-main.
- Cross concurrency boundaries with `Sendable` values.
- Keep AVCapture objects inside `CameraController`.
- Never perform disk reads, bundle audio decoding, or full-resolution image decoding inside a SwiftUI `body`.
- Cancel work that can outlive its screen or be replaced by newer work.
- Guard asynchronous render and metadata results against stale completions.

Do not mark new types `@unchecked Sendable` unless framework ownership is contained and the safety reasoning is explicit.

## Music and tonal identity rules

The same persisted root pitch class must drive:

- `MusicHarmony.rootPitchClass`;
- the persisted Cover palette;
- Inspector background identity.

Use `PitchClass` and `RetroCoverRenderer.tonalPalette(for:)` as the canonical mapping. Do not create another note-color table.

The live Capture lava lamp is provisional and may differ from the final Cover because Capture samples live camera color while the persisted pipeline uses weighted analysis of the normalized image.

Preserve deterministic behavior for the same stable inputs and current algorithm. Random-looking choices must use stable seeds, not runtime randomness, `Hasher`, `Date`, or newly generated UUIDs.

Do not put photo analysis, sequence generation, Jam arrangement, groove selection, sample loading, or audio rendering in views.

## Audio rules

`MusicNote.voiceRole` separates transient Jam voices from persisted single-photo notes:

- persisted Gallery/Inspector notes normally have `voiceRole == nil` and use the legacy procedural waveform path;
- Jam Bass notes use `.bass` and the procedural Future Bass renderer;
- Jam Harmony notes use `.harmony` and Dap Analog Family samples;
- Jam Melody notes use `.melody` and Dap Analog Family samples.

When a role-specific sample is unavailable, preserve the existing procedural fallback and keep it routed through the same semantic stem.

Preserve these current audio contracts unless explicitly changed:

- stereo 44,100 Hz output;
- one shared engine and player node;
- loop frame count fixed to one 16-step bar;
- Bass and Harmony duck from actual kick-hit frames;
- Melody is not ducked;
- percussion is mixed after tonal stems;
- final output is clamped, without a general limiter or mastering graph.

Do not add an effects graph, mixer-node architecture, sampler graph, SoundFont runtime, or generic audio plugin system without an explicit specification.

## Audio resource rules

Bundled audio is loaded by exact folder and filename contracts.

- `DapAnalogFamily` and `Drums` are folder resources in the app target.
- Current loaders require 44,100 Hz assets.
- Melodic assets are expected to be mono.
- Drum assets may be mono or stereo.

When adding, removing, renaming, or moving audio resources:

1. update the corresponding sample library;
2. verify the folder resource remains in `PBXResourcesBuildPhase`;
3. inspect `project.pbxproj`;
4. do not silently alter existing kit mappings or trims.

Do not expose unused sample assets as product behavior merely because they are bundled.

## Jam rules

Current Jam is a local Vibe experience, not a generic music workstation.

Preserve these contracts unless a new specification changes them:

- select one to three Musical Photos;
- assign roles deterministically by register, note count, and UUID;
- one photo becomes Melody;
- two photos become Bass and Melody;
- three photos become Bass, Harmony, and Melody;
- build one 16-step arrangement at fixed 96 BPM;
- derive one global pentatonic harmony from all selected photos;
- interpolate density, register bias, and gate between Airy, Bright, Deep, and Intense;
- choose one of three deterministic grooves per region;
- support Auto, Soft, Club, Break, and Metal Drum Kit selections;
- resolve Auto as Airy→Soft, Bright→Club, Deep→Break, Intense→Metal;
- schedule live replacements through the shared `MusicPlayer` and apply them at the next loop boundary.

### Melody ownership contract

The Musical Photo assigned `.melody` is the primary source of Melody pitch material.

All selected photos currently influence:

- global root and scale;
- role assignment;
- the sorted UUID portion of the Melody seed;
- Bass and Harmony accompaniment.

They do not currently contribute equal note pools to the Melody. Do not combine all selected note pools without an explicit musical specification and listening validation.

### Melody Motif Engine contract

The current Motif Engine:

- transforms the `.melody` photo's notes through register shift and global-scale snap;
- derives a stable FNV-1a seed;
- chooses an anchor, contour, regional rhythm template, and attack roles;
- builds an A phrase in steps 0...7 and an A' variation in steps 8...15;
- supports ascending, descending, arch, valley, pendulum, and repeated-anchor contours;
- permits pitch, rhythm, octave, or velocity variation;
- limits Melody to MIDI 60...96;
- avoids close Bass conflicts where possible;
- does not use per-note duration or Melody microtiming.

Do not replace this with unconstrained random note selection or a Foundation Model.

The seed currently includes transformed source-note step and MIDI values. Because transformed MIDI depends on rounded register shift, a Vibe movement can indirectly change the motif at register thresholds even though raw XY coordinates are not hashed. Treat this as a known current behavior, not as guaranteed continuous morphing.

Do not prebuild Studio, graph connections, timelines, saved Jam documents, multiplayer, collaboration, or plugin architecture.

## Persistence rules

Current persistence is deliberately simple:

- `Application Support/Dap/library.json`;
- `Application Support/Dap/Covers/<UUID>.png`.

A Musical Photo is considered created only after the essential object and Cover are persisted successfully.

The original Source Image is not currently persisted. Jam arrangements, selections, Vibe state, Drum Kit selection, and effects are not persisted.

Do not add Core Data, SwiftData, CloudKit, a repository layer, migrations, or multiple stores without an explicit product requirement.

## Foundation Models rules

Use Foundation Models only where generative interpretation provides user value.

Current approved use is progressive photo naming and description after the deterministic Musical Photo has already been saved.

Do not use a model to replace deterministic requirements such as:

- saving the photo;
- choosing the persisted UUID;
- generating the Cover;
- constructing the base Musical Sequence;
- assigning Jam roles;
- generating grooves or melodic motifs;
- reproducing a Jam arrangement.

Always handle model unavailability and generation failure without blocking the core flow.

## Prohibited patterns

Do not introduce without explicit approval:

- coordinators, routers, orchestrators, use-case layers, or repositories;
- protocols with one concrete implementation solely for abstraction;
- generic audio, effects, plugin, or processing frameworks;
- third-party packages;
- duplicate state owners;
- speculative persistence models;
- empty placeholder folders;
- automatic commits;
- broad rewrites for a local bug;
- tests or build pipelines not requested by the user.

## Completion report

At the end of an implementation task, report:

1. files changed;
2. behavior implemented;
3. important architectural or musical decisions;
4. validation actually performed;
5. unresolved issues, assumptions, or listening risks;
6. whether a build, test, simulator run, profiling session, commit, or push was intentionally not performed.

Be precise. Do not present assumptions or unperformed listening checks as verified facts.
