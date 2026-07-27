# Dap Product and Code Context

Last synchronized with the supplied repository worktree: 2026-07-26.

This document records the current product, domain model, implemented flows, deterministic algorithms, audio runtime, module ownership, and known gaps. It is a state document, not a changelog or roadmap.

When this file conflicts with the code, inspect the code and update this document.

## Product definition

Dap is an iOS app that transforms a captured or imported Source Image into a **Musical Photo**:

- a deterministic four-tone pattern-halftone Cover;
- a deterministic 16-step Musical Sequence;
- a root pitch class, scale, BPM, gate, octave range, and waveform profile;
- optional generated name and description.

Musical Photos can be browsed and played individually or combined transiently in **Jam**, where up to three photos are assigned Bass, Harmony, and Melody roles and interpreted through a Vibe XY control, deterministic grooves, selectable drum kits, role-specific voices, and a looping transport.

The app is local-first. No account, network service, cloud sync, analytics, multiplayer, or remote generation is required by the current code.

## Implemented product surface

### Root

`AppRootView` owns:

- one shared `PhotoLibraryViewModel`;
- Gallery/Jam section selection;
- Gallery UUID navigation path;
- full-screen Capture presentation;
- the root Gallery/Jam segmented switcher;
- the centered Capture button shown only at the Gallery root.

Gallery and Jam remain mounted and switch through opacity and hit-testing. Root chrome is hidden while Photo Inspector is pushed.

### Gallery

Gallery currently provides:

- a three-column grid of persisted Covers;
- newest-first ordering from the shared library state;
- an empty state when the library has no items;
- an in-memory Cover cache;
- a metadata-refinement progress indicator;
- a playing indicator for the active Musical Photo;
- UUID navigation to Photo Inspector;
- a native zoom transition when Reduce Motion is disabled;
- top and bottom material fades integrated with root chrome.

Gallery does not currently implement multi-selection, delete, share, manual reordering, Year/Month grouping, or a Gallery-local import tile.

### Photo Inspector

Photo Inspector currently provides:

- the selected Cover;
- a background derived from the final root-note palette;
- generated name and description when available;
- root, scale, and BPM information;
- play/pause through the shared `MusicPlayer`;
- a Gallery-to-Inspector zoom transition when motion is allowed.

`Add Effects`, `Add to Jam`, and the overflow action are visible placeholders and do not currently perform product actions.

### Capture

Capture is a full-screen AVFoundation camera flow.

Current controls and behavior:

- rear/front camera switching;
- flash toggle when supported;
- 1×/2× zoom toggle;
- shutter capture;
- ordered multi-photo import through PhotosUI;
- latest-Cover thumbnail that returns to Gallery;
- permission, configuration, ready, processing, completion, and failure states;
- orientation-aware preview and capture;
- front-preview mirroring while persisted captures remain unmirrored;
- live provisional pitch-color sampling;
- a Metal lava-lamp strip driven by the provisional pitch palette.

Interactive dismissal is disabled while Capture owns a blocking state. The normal exit path is the Gallery thumbnail or the explicit completion action shown after applicable import outcomes.

A successful shutter capture:

1. captures Source Image data;
2. processes and persists the Musical Photo;
3. updates the shared library and latest Cover thumbnail;
4. returns Capture to ready state without dismissing it.

Photos import supports up to 20 ordered images. Processing is sequential. Successful items remain saved when another item fails. Batch state reports progress and partial failure.

### Jam Vibe

Jam is implemented as a local, transient Vibe experience.

Current behavior:

- select one to three persisted Musical Photos in a sheet;
- ignore selected photos whose sequences contain no notes;
- assign deterministic Bass, Harmony, and Melody roles;
- display selected photos and assigned roles;
- control density, register bias, and gate with an XY pad;
- interpolate continuously between Airy, Bright, Deep, and Intense presets;
- classify the current Vibe into one of four groove regions;
- select one of three deterministic 16-step grooves per region;
- choose Drum Kit `Auto`, `Soft`, `Club`, `Break`, or `Metal`;
- map Auto as Airy→Soft, Bright→Club, Deep→Break, Intense→Metal;
- render sampled drums with kick, snare, closed hat, open hat, and rim events;
- render procedural Future Bass, sample-based Harmony, and sample-based Melody;
- apply kick-driven pumping to Bass and Harmony;
- generate Melody as a deterministic A/A' motif;
- play one fixed 16-step loop at 96 BPM;
- display a local transport step indicator;
- queue selection, Vibe, and kit changes while playing;
- schedule the latest rendered replacement for the next loop boundary;
- stop transient playback when Jam disappears or loses root focus.

Jam state is not persisted. Studio does not exist in the current code.

## Domain glossary

### Source Image

Raw image data received from AVFoundation capture or PhotosUI import.

The Source Image is used during processing and optional metadata refinement. It is not currently persisted after creation.

### Musical Photo

The persisted photo-derived object represented by `PhotoSound`.

A Musical Photo contains:

- stable UUID;
- optional name;
- optional description;
- creation date;
- Cover filename;
- `MusicSequence`.

### Cover

The persisted PNG visual generated from the normalized Source Image using a pitch-derived four-tone palette and clustered-dot pattern halftone.

The Cover is not the original Source Image.

### Musical Sequence

The deterministic playable value represented by `MusicSequence`:

- `MusicHarmony`;
- an array of `MusicNote` values;
- `SoundProfile`.

The grid is fixed at 16 steps by 8 rows.

Persisted photo notes normally have no `voiceRole`. Jam arrangements create transient notes with `.bass`, `.harmony`, or `.melody` roles.

### Musical Identity

The tonal identity derived during photo analysis:

- root pitch class;
- root-note color palette;
- scale;
- BPM;
- waveform;
- gate;
- octave range.

The root pitch class is the canonical connection between music, persisted Cover color, and Inspector background color.

### Voice Role

`MusicVoiceRole` identifies transient Jam rendering behavior:

- `.bass` → procedural Future Bass stem;
- `.harmony` → Dap Analog Family Harmony samples;
- `.melody` → Dap Analog Family Melody samples.

A nil role keeps the legacy procedural photo-playback path.

### Metadata

Optional name and description generated after the essential Musical Photo is persisted.

Metadata is enrichment. It must never determine whether Musical Photo creation succeeds.

### Playback

Audio rendering of a `MusicSequence`, optionally with a `MusicPercussionPattern`, through the single shared `MusicPlayer`.

### Percussion Pattern

A transient `MusicPercussionPattern` containing:

- resolved `MusicDrumKit`;
- kick hits;
- snare hits;
- closed-hat hits;
- open-hat hits;
- rim hits with Soft, Main, or Hard style.

### Drum Kit Selection

The UI-level selection is `Auto`, `Soft`, `Club`, `Break`, or `Metal`.

`Auto` resolves from the current Jam region. The resulting concrete `MusicDrumKit` is stored in the percussion pattern passed to the renderer.

### Jam Arrangement

A transient `JamArrangement` containing:

- one combined `MusicSequence`;
- active steps by source Musical Photo UUID;
- one percussion pattern.

It is built in memory and is not persisted.

### Vibe

The current Jam interaction mode. A normalized `CGPoint` bilinearly interpolates four corner presets:

- Airy: top-left;
- Bright: top-right;
- Deep: bottom-left;
- Intense: bottom-right.

The groove region itself uses quadrant boundaries at `x == 0.5` and `y == 0.5`.

### Studio

A possible future explicit arrangement mode. It is not implemented and has no authorized architecture in the current repository.

## Core workflows

### Application startup

`DapApp → AppRootView → PhotoLibraryViewModel.loadLibrary() → PhotoStore.load() + coverData(for:)`

The library is loaded once per shared view-model lifetime. Covers are loaded into memory before the views render them.

### Create from camera

`CameraController → Source Image Data → PhotoMusicPipeline → PhotoStore.save → PhotoLibraryViewModel memory update → metadata refinement`

Capture remains presented after a successful shutter creation.

### Create from Photos

`PhotosPickerItem → Data → PhotoMusicPipeline → PhotoStore.save → batched memory publication → sequential metadata refinement`

Batch processing continues after individual failures unless the task is cancelled.

### Inspect and play

`Gallery UUID path → PhotoInspectorView → PhotoLibraryViewModel.toggle(sound:) → shared MusicPlayer`

Only one shared playback runtime exists.

### Create and play a Jam

`Jam selection → JamArrangementBuilder → JamGrooveLibrary → PhotoLibraryViewModel.playTransientSequence → MusicPlayer loop`

The builder receives the concrete Drum Kit already resolved by `JamView`.

## Deterministic photo pipeline

`PhotoMusicPipeline.process(imageData:)` runs heavy work in a detached user-initiated task and returns Sendable values.

### 1. Decode and normalize

The Source Image is decoded with `UIImage` and redrawn into a new `CGImage` so orientation is applied before analysis and rendering.

### 2. Color analysis

The normalized image is drawn into a 64×64 RGBA buffer.

The analysis computes:

- mean RGB, hue, saturation, and luminance;
- chromatic hue samples;
- circular hue variance;
- Sobel edge density;
- twelve weighted hue bins;
- a stable FNV-style seed from pixel bytes.

The root pitch class is selected from softened weighted hue bins using the stable seed. The result is deterministic for the same analyzed pixels and current algorithm.

Current color-pipeline algorithm constant: `2`.

### 3. Tone analysis

A four-tone Floyd-Steinberg image is generated at target width 160 pixels. This legacy dithered image is used only for tone analysis, not as the persisted Cover.

Tone analysis derives:

- significant tone count from the full dithered image;
- a 16×8 tone grid for note generation.

### 4. Sequence construction

Current mappings:

- root: selected root pitch class;
- BPM: luminance mapped and clamped to 70...140;
- scale:
  - high hue variance → whole tone;
  - medium hue variance → dorian;
  - otherwise saturation chooses major or minor pentatonic;
- octave range: significant tone count;
- gate: Sobel edge density mapped from long to short;
- waveform:
  - hue from 90° through under 300° → square;
  - remaining hues → triangle;
- notes: nonzero levels from the 16×8 tone grid.

If the tone grid produces no notes, the pipeline inserts four fallback notes at quarter-bar steps using the middle row.

### 5. Cover rendering

The persisted Cover is rendered from the normalized original image, not from the low-resolution analysis dither.

`RetroCoverRenderer.patternHalftone`:

- limits the maximum output dimension to 1024 pixels;
- computes luminance with a mild contrast adjustment;
- quantizes across four colors;
- uses a 4×4 clustered-dot threshold matrix;
- uses a matrix pixel scale of 2;
- preserves alpha.

### 6. Tonal palette

`PitchClass.canonicalColor` defines twelve canonical pitch colors.

`RetroCoverRenderer.tonalPalette(for:)` derives:

- shadow;
- dark;
- base;
- highlight.

This is the canonical pitch-to-color path. The persisted Cover and Inspector use the final pipeline root. Capture uses the same palette function with a provisional live-camera root, so Capture color may differ from the final persisted result.

### 7. Essential persistence

The pipeline creates a new UUID, a `PhotoSound` with nil metadata, and PNG Cover data. The essential result is persisted before it appears in shared state.

### 8. Progressive metadata

After persistence, `PhotoMetadataGenerator`:

1. classifies the Source Image with Vision;
2. keeps up to five labels with confidence of at least 0.12;
3. builds a prompt from visual labels and Musical Identity;
4. uses a new Foundation Models session for each photo;
5. requests a short English name and one-sentence description;
6. sanitizes and length-limits generated text;
7. patches only `name` and `description` in persistence and memory.

Unavailable models, classification failures, guardrail failures, and generation failures preserve the fallback metadata state.

## Audio runtime

`MusicPlayer` is a `@MainActor` concrete runtime with:

- one `AVAudioEngine`;
- one `AVAudioPlayerNode`;
- stereo 44,100 Hz output;
- lazy audio-session activation and engine startup;
- cancellable detached offline rendering;
- generation tokens that reject stale completions;
- one-shot scheduling;
- native looping;
- debounced loop replacement;
- audio-interruption handling.

All tonal and percussion content is rendered into arrays before an `AVAudioPCMBuffer` is scheduled.

### Single-photo procedural playback

Persisted Gallery and Inspector sequences normally contain notes with `voiceRole == nil`.

Those notes use the legacy procedural path:

- square or triangle waveform table from `SoundProfile`;
- MIDI-to-frequency conversion;
- shared gate envelope;
- velocity scaling through `tonalGain`;
- stereo duplication;
- final output clamp.

This path is intentionally preserved so Jam voice changes do not alter persisted single-photo playback.

### Jam melodic routing

Jam notes are split into semantic stems inside `renderSequence`:

- Bass stem;
- Harmony stem;
- main output for Melody and nil-role notes.

Role-specific fallbacks remain inside their semantic stem so Bass and Harmony still receive pumping when a preferred renderer is unavailable.

### Future Bass

The primary Jam Bass renderer is procedural and monophonic.

Current voice characteristics:

- sine sub: 0.50;
- saw: 0.35;
- triangle: 0.15;
- fast attack;
- decay and sustain envelope;
- dynamic low-pass contour;
- tanh saturation;
- gain scaled by note velocity;
- 85 ms glide only when consecutive Bass events overlap musically;
- Bass timing offsets clamped to approximately -0.06...+0.08 steps.

The bundled Bass samples in `DapAnalogFamily` are not the primary current Bass path.

### Harmony and Melody samples

`MelodicSampleLibrary` loads mono 44,100 Hz WAVs and selects the nearest root sample with linear interpolation during playback.

Bundled root samples:

- Harmony: C3, C4, C5, C6;
- Melody: C4, C5, C6, C7;
- Bass assets also exist at C2, C3, C4, but the current renderer uses Future Bass instead.

Playback ranges:

- Bass library range: MIDI 36...60;
- Harmony: MIDI 48...84;
- Melody: MIDI 60...96.

Current role gains:

- Bass renderer: 0.70;
- Harmony sample path: 0.44;
- Melody sample path: 0.50.

Harmony uses at least 75% of one step as its musical gate and is cut at the next Harmony attack when earlier. Existing role-specific fades are preserved.

If a Harmony or Melody sample cannot load, the note falls back to the procedural waveform renderer.

### Kick-driven pumping

Actual `percussion.kickHits` are converted to sorted unique frame positions.

Offline quadratic ease-out gain envelopes are applied before drums are mixed:

- Bass minimum gain: 0.72;
- Bass release: 170 ms;
- Harmony minimum gain: 0.54;
- Harmony release: 210 ms;
- Melody: no ducking.

Overlapping duck envelopes use the minimum required gain rather than multiplication, so consecutive kicks do not push the signal below the configured minimum.

Pumping is not circular across the loop boundary. A kick at step 0 starts a new envelope at frame 0.

### Percussion rendering

`DrumSampleLibrary` loads bundled WAV resources and exposes four concrete kits:

- Soft;
- Club;
- Break;
- Metal.

Each kit defines kick, snare, closed hat, open hat, shared rim samples, and per-voice trims.

The renderer supports:

- mono or stereo samples;
- kick, snare, closed-hat, open-hat, and rim events;
- open-hat choking from closed hats;
- Soft, Main, and Hard rim styles;
- loop wrapping for sample tails;
- procedural kick, snare, and closed-hat fallback if a required sample is unavailable.

The resource bundle also contains additional claps, cymbals, shakers, tambourines, textures, and unused alternates. Their presence does not mean they are currently selected by any kit.

### Output and loop scheduling

For looping Jam playback, frame count is exactly one 16-step tonal bar. Sample tails wrap inside that frame count.

When `play(... loops: true)` is called while a loop is already playing:

1. pending replacement work is cancelled;
2. a new generation token is created;
3. rendering is debounced by approximately 135 ms;
4. only the latest render completion remains valid;
5. the new buffer is scheduled with `.loops` and `.interruptsAtLoop`;
6. `onLoopUpdatePrepared` informs Jam that the replacement is queued.

The visible Jam transport is a separate `ContinuousClock` task. It clears prepared Drum Kit feedback at step 0 after scheduling confirmation.

## Jam arrangement algorithm

### Selection

Jam accepts up to three Musical Photos. Selector output is sorted by UUID for stable storage. Photos with empty sequences are excluded from arrangement building.

### Role assignment

Photos are sorted by:

1. average MIDI register;
2. note count;
3. UUID string.

Roles are assigned as:

- one photo → Melody;
- two photos → Bass and Melody;
- three photos → Bass, Harmony, and Melody.

### Global harmony

All selected notes are counted by pitch class. The builder evaluates every root for major pentatonic and minor pentatonic and selects the candidate with greatest note coverage.

Ties prefer:

1. major pentatonic over minor pentatonic;
2. lower root pitch class within the same scale.

All selected photos influence this root and scale.

### Vibe interpolation

The XY position bilinearly interpolates four presets:

| Preset | Density | Register bias | Gate |
|---|---:|---:|---:|
| Airy | 0.40 | +7 | 0.72 |
| Bright | 0.72 | +12 | 0.42 |
| Deep | 0.34 | -12 | 0.78 |
| Intense | 0.82 | -5 | 0.34 |

Density is further scaled by role:

- Bass: 0.60;
- Harmony: 0.80;
- Melody: 1.00.

### Bass transformation

Bass:

- uses one representative source note per step;
- samples by effective Bass density;
- maps pitch classes to global root or fifth;
- keeps a low register;
- applies deterministic velocity accents;
- applies structured microtiming for selected pickups and offbeats;
- marks notes with `voiceRole == .bass`.

### Harmony transformation

Harmony:

- uses one representative source note per step;
- samples by effective Harmony density;
- snaps to global harmony;
- keeps a middle register;
- reduces source velocity;
- marks notes with `voiceRole == .harmony`.

### Melody source scope

The Melody's primary pitch material comes from only one Musical Photo: the photo assigned the `.melody` role.

The builder passes only that photo's source notes through:

`source notes → register shift → global-scale snap → transformed Melody pool`

All selected photos still influence:

- global root and scale;
- sorted UUIDs used by the Melody seed;
- Bass and Harmony accompaniment;
- which photo becomes the Melody role.

The other photos do not currently add equal pitch candidates to the Melody pool.

### Melody Motif Engine

The Motif Engine replaces the previous one-to-one sampled-note transformation.

It builds:

- phrase A in steps 0...7;
- related variation A' in steps 8...15;
- one anchor pitch class;
- one regional contour;
- one regional rhythm template;
- semantic attack roles: anchor, passing, climax, resolution.

Available contours:

- ascending;
- descending;
- arch;
- valley;
- pendulum;
- repeated anchor.

Regional attack counts per half:

- Airy: 2 or 3;
- Bright: 3 or 4;
- Deep: 2 or 3;
- Intense: 4 or 5.

Regional rhythm templates:

- Airy: `[1,4,7]`, `[0,3,6]`, `[2,5]`;
- Bright: `[0,2,5,7]`, `[1,3,6]`, `[0,3,5,7]`;
- Deep: `[0,4,7]`, `[2,5]`, `[1,4,6]`;
- Intense: `[0,2,3,6,7]`, `[1,2,4,6]`, `[0,3,4,5,7]`.

A' preserves the anchor and contour and may apply one deterministic variation kind:

- internal pitch change;
- internal one-step rhythm shift;
- octave shift at the A' climax;
- velocity accent.

Additional rules:

- stable degrees prefer root, third, fifth, then seventh when present;
- source-note occurrence helps select the anchor;
- Melody remains within MIDI 60...96;
- no more than one octave jump is permitted per loop;
- octave variation is available only to Bright and Intense selection sets;
- large leaps are softened when not intentional;
- repeated single-note halves are normalized with a scale-neighbor adjustment;
- close simultaneous Bass conflicts are resolved by octave displacement or scale-neighbor choice;
- Melody notes keep `timingOffsetSteps == nil`;
- per-note duration does not exist in the current model, so Melody articulation is expressed through attack spacing and velocity.

### Melody determinism

The local FNV-1a 64-bit seed includes:

- selected UUID strings in sorted order;
- global root pitch class;
- global scale raw value;
- Jam region;
- transformed Melody source-note step and MIDI values.

Runtime randomness, `Hasher`, `Date`, and new UUID generation are not used.

Raw `vibePosition` is not hashed. However, transformed Melody MIDI values depend on rounded register shift. Crossing a register-shift threshold can therefore change the seed and rebuild the motif even inside the same region. This is a current known behavior.

### Groove selection

The Vibe quadrant selects Airy, Bright, Deep, or Intense.

Each region has three hard-coded 16-step variants. Variant index is derived from FNV-1a hashing of sorted selected UUID strings, so the same selected set and region produce the same pattern.

Patterns can contain kick, snare, closed hat, open hat, and rim events with velocity.

### Drum Kit resolution

`JamView` owns UI selection and resolves a concrete kit before building the arrangement.

Auto mapping:

- Airy → Soft;
- Bright → Club;
- Deep → Break;
- Intense → Metal.

Manual kit selection persists while Vibe moves. Changes during playback are rendered through the same next-loop replacement path.

### Playback update contract

Jam playback is one native looping rendered buffer at 96 BPM. The visible transport advances with a local `ContinuousClock` task.

While playing:

- Vibe movement marks an arrangement change as pending;
- photo selection changes mark an arrangement change as pending;
- Drum Kit changes immediately send the latest arrangement to `MusicPlayer`, which owns debouncing and next-loop quantization;
- only the latest replacement render remains valid;
- prepared kit feedback clears at the next visible step 0.

## Persistence

`PhotoStore` is an actor and owns all disk state under Application Support:

```text
Dap/
├── library.json
└── Covers/
    └── <UUID>.png
```

### Save contract

1. create directories;
2. write Cover PNG;
3. prepend and newest-sort the updated library;
4. atomically write `library.json`;
5. remove the new Cover if the JSON write fails;
6. publish memory state only after full persistence success.

### Metadata patch contract

Metadata updates read, modify, and atomically rewrite the library inside one actor turn. Only name and description change.

### Current persistence gaps

The app does not persist:

- original Source Images;
- Jam selection;
- Vibe position;
- Drum Kit selection;
- Jam arrangements;
- effects;
- Gallery user ordering;
- export history;
- algorithm-version metadata or migrations.

## Module ownership

### `DapApp`

Creates `AppRootView`.

### `AppRootView`

Owns root section, Gallery path, Capture presentation, root chrome, and shared `PhotoLibraryViewModel` lifetime.

### `PhotoLibraryViewModel`

Owns in-memory library items, Cover cache, import state, metadata task coordination, shared playback, and transient loop-prepared callback plumbing.

Despite its name, it is shared by Gallery, Capture, Inspector, and Jam.

### `PhotoStore`

Owns library JSON, Cover files, serialized saves, metadata patches, and Cover loading.

### `PhotoMusicPipeline`

Owns deterministic image analysis, base Musical Sequence construction, Musical Identity, and Cover generation.

### `RetroCoverRenderer`

Owns canonical pitch colors, tonal palettes, pattern halftone, Floyd-Steinberg analysis rendering, and pixel-level helpers.

### `PhotoMetadataGenerator`

Owns Vision classification, Foundation Models prompting, guided output, sanitization, and graceful failure.

### `MusicPlayer`

Owns the audio graph, offline tonal and percussion rendering, role-based stems, Future Bass, sample playback, pumping, looping, scheduling, cancellation, and interruptions.

### `MelodicSampleLibrary`

Owns Dap Analog Family sample loading, nearest-root lookup, and role playback ranges.

### `DrumSampleLibrary`

Owns drum sample loading, concrete kit mappings, and kit trims.

### `CameraView`

Owns Capture UI state and the user-facing creation/import flow.

### `CameraController`

Owns AVCaptureSession, device input, outputs, preview attachment, orientation, mirroring, flash capability, zoom, switching, capture, and sampled preview pitch color.

### `GalleryView`

Owns grid presentation and UUID navigation to Inspector.

### `PhotoInspectorView`

Owns one-photo presentation and its current playback controls.

### `JamView`

Owns transient photo selection, Vibe position, Drum Kit selection, selector presentation, playback state, pending feedback, and visible transport.

### `JamArrangementBuilder`

Owns role assignment, global harmony, Vibe interpolation, Bass and Harmony transformation, Melody Motif Engine, and active-step attribution.

### `JamGrooveLibrary`

Owns groove-region classification, stable set hashing, and the twelve hard-coded percussion variants.

## Domain invariants

1. Every successfully persisted Musical Photo has one stable UUID.
2. The essential Musical Photo and Cover persist before shared memory publishes the item.
3. Metadata is optional and never changes the Cover or Musical Sequence.
4. The original Source Image is not part of the persisted Musical Photo today.
5. Gallery reads Covers from the shared in-memory cache, not from disk during view rendering.
6. The persisted library is newest-first.
7. One shared `MusicPlayer` arbitrates all playback.
8. Starting a non-looping playback path stops the previous path.
9. A running Jam loop receives replacement arrangements through latest-wins next-loop scheduling rather than a second engine.
10. Capture acquires Source Images but does not own persisted library state.
11. Inspector presents an existing Musical Photo and does not duplicate it.
12. The root pitch class is the canonical source for pitch-color identity.
13. Photo creation and Jam generation are deterministic for stable inputs and current algorithms.
14. Jam references Musical Photos by stable UUID and does not mutate persisted sequences.
15. Jam is transient and local in the current product.
16. Only the photo assigned `.melody` supplies the current primary Melody note pool.
17. All selected photos contribute to global Jam harmony.
18. Melody and Harmony samples are role-specific Jam behavior; nil-role photo playback remains procedural.
19. Drum Kit selection changes instrumentation, not the underlying regional groove pattern.
20. Melody has no per-note duration or effective microtiming in the current model/runtime.

## Current intentional gaps and risks

The following are not implemented and must not be assumed to exist:

- audio effects;
- persisted per-photo effects;
- global Jam effects;
- Studio mode;
- saved Jam documents;
- export of images, audio, MIDI, or animations;
- Gallery selection, delete, share, grouping, and reordering;
- direct Inspector-to-Jam insertion;
- cloud sync;
- multiplayer or collaboration;
- remote services;
- analytics;
- a test target.

Current technical or musical risks:

- the latest Melody Motif Engine requires listening validation across all twelve grooves and varied photo sets;
- Melody A/A' identity can change at rounded register-shift thresholds because transformed MIDI values enter the seed;
- additional selected photos alter Melody context and seed but do not currently contribute equal Melody note material;
- pumping is not circular across the loop boundary;
- there is no per-note duration model for Melody articulation;
- final output uses clamping rather than a dedicated limiter/master stage;
- bundled audio contains assets not currently exercised by product behavior.

These are possible future tasks, not authorization to prebuild their architecture.

## Naming

Use these product terms in new documentation and copy:

- **Musical Photo** or **Photo**: the persisted photo-derived object;
- **Source Image**: raw captured or imported image data;
- **Cover**: generated four-tone visual;
- **Musical Sequence**: deterministic playable note data;
- **Musical Identity**: root, scale, BPM, profile, and tonal color;
- **Jam**: the multi-photo music experience;
- **Vibe**: the current XY Jam mode;
- **Drum Kit**: the concrete Jam percussion sound set;
- **Photo Inspector**: the detail screen;
- **Studio**: a deferred explicit arrangement mode.

Existing symbols such as `PhotoSound` and `PhotoLibraryViewModel` may remain. Do not perform broad renames without an explicit task.

## Decisions that still require an explicit product specification

Do not guess:

- whether Source Images should be persisted;
- whether future algorithm versions regenerate existing Musical Photos;
- how algorithm-version migration should work;
- whether effects belong to a Photo, Jam, or both;
- whether effects are persisted;
- whether Jam BPM becomes variable;
- whether Vibe groove regions retain hard quadrant boundaries;
- whether Melody should borrow note material from non-Melody photos;
- whether Jam should support more than three photos and how extra roles behave;
- whether the bundled Bass samples should replace or complement Future Bass;
- whether Jam state is saved;
- how deleted Photos affect future saved Jams;
- how Gallery selection, grouping, and ordering should work;
- what export formats and animation system are required;
- what Studio means as an interaction and data model.

## Documentation maintenance

Update this file when any of these change:

- implemented product surface;
- domain vocabulary;
- persistence schema;
- module ownership;
- deterministic photo or Jam algorithms;
- sample or kit mappings;
- playback architecture;
- Jam lifecycle;
- an intentional gap becomes implemented.

Do not use this document for commit history. Keep it synchronized with the current repository state.
