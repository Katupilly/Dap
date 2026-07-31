# Dap Product and Code Context

Last synchronized with the supplied repository worktree: 2026-07-29 (commit `e80c79f`).

This document records the current product, domain model, implemented flows, deterministic algorithms, audio runtime, module ownership, and known gaps. It is a state document, not a changelog or roadmap.

When this file conflicts with the code, inspect the code and update this document.

## Product definition

Dap is a native iOS app that transforms a captured or imported Source Image into a **Musical Photo**:

- a deterministic four-tone pattern-halftone Cover;
- a deterministic 16-step Musical Sequence;
- a root pitch class, scale, BPM, gate, octave range, and waveform profile;
- optional generated name and description.

Musical Photos can be browsed, shared, deleted, and played individually. They can also be added to a saved **Jam** document, where up to three photos occupy Bass, Harmony, and Melody roles and are interpreted through Vibe, deterministic grooves, role-specific arrangement variations, selectable Drum Kits, global effects, and a looping transport.

Jams are local persisted documents with a name, role assignments, Vibe position, Drum Kit, effect settings, and variation state. Their rendered arrangement and audio buffer remain transient derivatives.

The app is local-first. No account, network service, cloud sync, analytics, multiplayer, or remote generation is required by the current code.

## Implemented product surface

### Root

`AppRootView` owns:

- one shared `PhotoLibraryViewModel`;
- Gallery/Jam section selection;
- Gallery UUID navigation path;
- full-screen Capture presentation;
- whether a Jam session is currently pushed;
- the root Gallery/Jam segmented switcher;
- the centered Capture button shown only at the Gallery root;
- consumption of deferred `DapPendingActionRequest` values created by App Intents.

Gallery and Jam remain mounted and switch through opacity and hit-testing. Root chrome is hidden while Photo Inspector or a Jam session is presented.

### Typography

ZT Talk is bundled locally in Regular, Medium, SemiBold, and Bold files and registered through `UIAppFonts`. `DapFont.swift` provides `Font.dap` helpers with Dynamic Type-relative sizing. Existing views still contain some direct `.custom(...)` calls; the helper is the canonical reusable entry point for new typography work.

### App Shortcuts

The app exposes two `AppShortcut` actions:

- **Take a Photo** opens Dap directly into Capture;
- **Create a Jam** switches to the Jam section and starts the inline new-Jam naming flow.

The intents do not mutate SwiftUI state directly. They enqueue one codable request in `UserDefaults`; `AppRootView` consumes and removes it when the scene is active, on defaults changes, and during startup.

### Gallery

Gallery currently provides:

- a three-column grid of persisted Covers;
- newest-first ordering from the shared library state;
- an empty state when the library has no items;
- an in-memory Cover cache;
- a metadata-refinement progress indicator;
- a playing indicator for the active Musical Photo;
- UUID navigation to Photo Inspector;
- top and bottom material fades integrated with root chrome.

Gallery does not currently implement multi-selection, manual reordering, Year/Month grouping, or a Gallery-local import tile. Import remains inside Capture.

### Photo Inspector

Photo Inspector currently provides:

- the selected Cover in a fixed portrait presentation;
- a background derived from the final root-note palette;
- a display title, optional generated description, root, scale, and BPM;
- play/stop through the shared `MusicPlayer`;
- PNG Cover sharing through `ShareLink` with the Cover as preview;
- destructive Photo deletion with confirmation and rollback-safe persistence;
- **Add to Jam**, including saved-Jam availability, capacity status, duplicate status, and inline Jam creation.

Adding a Photo to a Jam updates only that Jam's persisted slot assignments. It does not navigate into the Jam session.

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
- a Metal lava-lamp strip driven by the provisional pitch palette;
- black preview chrome in both appearance modes.

Interactive dismissal is disabled while Capture owns a blocking state. The normal exit path is the Gallery thumbnail or the explicit completion action shown after applicable import outcomes.

A successful shutter capture:

1. captures Source Image data;
2. processes and persists the Musical Photo;
3. updates the shared library and latest Cover thumbnail;
4. returns Capture to ready state without dismissing it.

Photos import supports up to 20 ordered images. Processing is sequential. Successful items remain saved when another item fails. Batch state reports progress and partial failure.

### Jam Library

Jam is entered through a persistent two-column library rather than a transient selector.

The library currently provides:

- load, search, create, open, rename, and delete flows;
- inline draft naming before a Jam is created;
- deterministic generated abstract Covers derived from the Jam ID, assigned Photo IDs, and pitch palettes;
- newest-updated-first ordering;
- explicit empty, search-empty, loading, and failure states;
- a bottom **Create a Jam** action hidden while search or inline editing owns focus.

Deleting a Jam removes only its JSON document. Musical Photos and their Covers remain intact.

### Jam Session

A Jam session is a persisted, sequencer-first workspace.

Current behavior:

- load and autosave one `PersistedJam`;
- select up to three Musical Photos, assigning playable Photos to active roles and retaining non-playable selections in reserve;
- maintain explicit Bass, Harmony, Melody, and reserve assignments;
- reconcile missing/deleted Photos against the shared library;
- display the Jam name and generated Jam Cover in the header;
- display role tiles, pitch labels, active-step feedback, and a unified 16-step sequencer/status surface;
- select a role by tapping its Photo tile;
- swap active roles through drag-and-drop or accessibility actions without recomputing assignment identity;
- open floating Kits, Vibe, Arrange, and Effects panels from the dock;
- render a blurred/rasterized session backdrop behind expanded panels while keeping the live sequencer overlay separate;
- control density, register bias, and gate with the Vibe XY pad;
- select Drum Kit `Auto`, `Soft`, `Club`, `Break`, or `Metal`;
- apply contextual deterministic arrangement variations to Bass, Harmony, or Melody;
- enable and adjust global Reverb, Delay, and LFO/tremolo;
- play one fixed 16-step loop at 96 BPM;
- derive visible step and active-photo state from the live `AVAudioPlayerNode` transport;
- queue latest-wins arrangement replacements for the next loop boundary;
- persist document state while keeping rendered arrangements and buffers transient;
- stop playback and flush/cancel session work when the view disappears, loses root focus, closes, or enters relevant lifecycle states.

The large Jam surface is split into focused presentation files (`JamPhotoSection`, `JamSequencerSection`, `JamDockBar`, `JamControlPanels`, and `JamPanelBackdrop`). `JamView` remains the orchestrator for session actions, persistence, and cross-component coordination.

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

`PhotoSound.nameSource` distinguishes manual and generated names. Generated refinement preserves an existing manual name while still allowing the description to update. `displayTitle` falls back to the Musical Sequence label and then `Untitled Photo` when no usable name exists.

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

### Saved Jam

The persisted Jam document represented by `PersistedJam`.

Schema version 1 stores:

- stable UUID, normalized name, creation date, and update date;
- Bass, Harmony, Melody, and reserve Photo UUID assignments;
- normalized Vibe position;
- Drum Kit selection;
- Reverb, Delay, and LFO settings;
- Bass, Harmony, and Melody variation state.

A Saved Jam references Musical Photos by UUID. It does not embed Photo sequences, Photo Covers, a rendered arrangement, or audio.

### Jam Arrangement

A transient `JamArrangement` containing:

- one combined `MusicSequence`;
- active steps by source Musical Photo UUID;
- one percussion pattern.

It is deterministically rebuilt from the Saved Jam state and current Musical Photo library. It is not persisted.

### Jam Effects

`JamEffectSettings` configures the global Jam effect rack:

- Reverb enable and wet mix;
- Delay enable and wet mix;
- LFO/tremolo enable and amount.

Settings are persisted in the Saved Jam, while DSP runtime state remains inside `MusicPlayer`.

### Vibe

The current Jam interaction mode. A normalized `CGPoint` bilinearly interpolates four corner presets:

- Airy: top-left;
- Bright: top-right;
- Deep: bottom-left;
- Intense: bottom-right.

The groove region itself uses quadrant boundaries at `x == 0.5` and `y == 0.5`.

### Studio

A possible future explicit arrangement mode. It is not implemented and has no authorized architecture in the current repository. The current contextual Arrange panel is part of Jam and is not Studio.

## Core workflows

### Application startup

`DapApp → AppRootView → PhotoLibraryViewModel.loadLibrary() → PhotoStore.load() + coverData(for:)`

The Musical Photo library is loaded once per shared view-model lifetime. Covers are loaded into memory before the views render them. The Jam library loads independently when `JamLibraryView` appears.

### Consume an App Shortcut

`AppIntent → DapPendingActionStore.enqueue → AppRootView.consumePendingActionIfNeeded()`

The root consumes the request only while active, removes it from defaults, resets incompatible presentation state, and opens Capture or the Jam draft-creation flow.

### Create from camera

`CameraController → Source Image Data → PhotoMusicPipeline → PhotoStore.save → PhotoLibraryViewModel memory update → metadata refinement`

Capture remains presented after a successful shutter creation.

### Create from Photos

`PhotosPickerItem → Data → PhotoMusicPipeline → PhotoStore.save → batched memory publication → sequential metadata refinement`

Batch processing continues after individual failures unless the task is cancelled.

### Inspect and play

`Gallery UUID path → PhotoInspectorView → PhotoLibraryViewModel.toggle(sound:) → shared MusicPlayer`

Only one shared playback runtime exists.

### Add a Photo to a Jam

`Photo Inspector → JamLibraryState/JamStore → JamSlotAssignments.addingPhotoID → PersistedJam save`

The operation rejects non-playable Photos, duplicates, and Jams already at the three-Photo limit.

### Create, open, and save a Jam

`JamLibraryView → JamLibraryState → JamStore → JamView`

`JamView` loads the document into `JamSessionState`, reconciles Photo UUIDs, rebuilds the transient arrangement, and autosaves document changes after a 500 ms debounce. Closing or backgrounding flushes pending persistence work where applicable.

### Create and play a Jam arrangement

`JamSessionState → JamArrangementBuilder → JamGrooveLibrary → PhotoLibraryViewModel.playTransientSequence/updateTransientLoop → MusicPlayer → JamAudioRenderer`

The builder receives explicit role assignments, deterministic variation state, and the concrete Drum Kit already resolved by `JamView`.

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
7. patches metadata through `PhotoStore.updateMetadata` with `nameSource == .generated`;
8. preserves a pre-existing manual name when `preserveManualName` is enabled.

Unavailable models, classification failures, guardrail failures, and generation failures preserve the already-persisted Musical Photo and its fallback display title.

## Audio runtime

`MusicPlayer` is the single `@MainActor` playback runtime with:

- one `AVAudioEngine`;
- a Gallery/Inspector player path;
- a dedicated Jam player path through LFO mixer → Delay → Reverb → main mixer;
- stereo 44,100 Hz output;
- lazy audio-session activation and engine startup;
- cancellable detached offline rendering delegated to `JamAudioRenderer`;
- generation and request tokens that reject obsolete completions;
- native Jam looping and debounced next-loop replacement;
- live Jam transport introspection from `AVAudioPlayerNode` render time;
- audio-interruption handling.

All tonal and percussion content is rendered into arrays before an `AVAudioPCMBuffer` is scheduled. SwiftUI views do not render audio.

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

`JamAudioRenderer` splits role-tagged notes into semantic stems:

- Bass;
- Harmony;
- Melody and nil-role main output.

Role-specific fallbacks remain inside their semantic stem so Bass and Harmony still receive pumping when a preferred renderer is unavailable. `MusicPlayer` owns only the engine graph, buffer scheduling, transport, and global effect units.

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

### Global Jam effects

The Jam path is:

`jamPlayerNode → jamLFOMixer → jamDelayUnit → jamReverbUnit → mainMixerNode`

Current behavior:

- Reverb uses `mediumHall` and maps enabled mix to `wetDryMix`;
- Delay time is dotted-eighth relative to BPM, feedback is 35%, and low-pass cutoff is 12 kHz;
- LFO is a global tremolo at half-note rate, updated at approximately 30 Hz;
- disabling an effect bypasses its wet stage or restores LFO mixer gain to 1;
- defaults are disabled with remembered mixes of Reverb 0.28, Delay 0.22, and LFO amount 0.35.

### Output and loop scheduling

Jam playback uses `playJam` on a dedicated looping node. Frame count is exactly one 16-step tonal bar at 96 BPM; sample tails wrap inside that frame count.

For an update while Jam is running:

1. the newest `LoopRenderRequest` supersedes older pending work;
2. replacement rendering is debounced by approximately 135 ms;
3. generation/request tokens reject stale completions;
4. the prepared buffer is scheduled with `.loops` and `.interruptsAtLoop` on the Jam node;
5. `onLoopUpdatePrepared` informs Jam that the replacement is queued;
6. `JamPlaybackController` promotes the matching pending arrangement only after a live transport wrap is observed.

The visible transport is polled from `MusicPlayer.currentJamTransportSnapshot()` at approximately 33 ms. `JamVisualTransportState` stores only the current step and active Photo UUID set, reducing broad SwiftUI observation invalidation.

## Jam arrangement algorithm

### Selection and slot ownership

A Saved Jam accepts up to three Musical Photos. `JamSlotAssignments` is the single source of truth for Bass, Harmony, Melody, and reserve membership.

Selector confirmation reconciles the requested UUID order with current assignments and playable IDs. Existing active roles survive when valid; newly added playable Photos fill canonical vacancies; deleted or unplayable active Photos can be demoted or removed; reserve Photos are promoted deterministically when needed.

The Jam selector can retain Photos with empty sequences, but they remain in reserve and cannot occupy an active playable role. Photo Inspector blocks adding a non-playable Photo directly to a Saved Jam. Arrangement building ignores unresolved or empty sources.

### Initial role assignment

For a fresh selection, playable Photos are sorted by:

1. average MIDI register;
2. note count;
3. UUID string.

Roles are assigned as:

- one photo → Melody;
- two photos → Bass and Melody;
- three photos → Bass, Harmony, and Melody.

After initial assignment, role identity is explicit state. Drag-and-drop swaps role UUIDs; it does not rerun the sorting algorithm.

### Global harmony

All selected notes are counted by pitch class. The builder evaluates every root for major pentatonic and minor pentatonic and selects the candidate with greatest note coverage.

Ties prefer:

1. major pentatonic over minor pentatonic;
2. lower root pitch class within the same scale.

All active assigned Photos influence this root and scale. Reserve Photos do not enter the arrangement builder.

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

### Contextual Arrange variations

Arrange operates on the currently selected playable role and persists only compact variation state.

Bass intents:

- Steady;
- Syncopated;
- Driving.

Harmony intents:

- Sustained;
- Rhythmic;
- Open.

Melody intents:

- Subtle;
- Energetic;
- Sparse;
- Surprise.

Bass and Harmony persist an intent plus generation counter. Melody persists a generation counter; the UI intent guides a deterministic search across rhythm, contour, register, and full variation families. Applying an option increments/searches generation until it finds a sufficiently different valid arrangement or uses the defined fallback path.

Variations remain deterministic for the same Jam document, source Photos, Vibe region, and current algorithm. They do not mutate persisted Musical Photo sequences.

### Melody source scope

The Melody's primary pitch material comes from only one Musical Photo: the photo assigned the `.melody` role.

The builder passes only that photo's source notes through:

`source notes → register shift → global-scale snap → transformed Melody pool`

All active assigned Photos still influence:

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

- active assigned UUID strings in sorted order;
- global root pitch class;
- global scale raw value;
- Jam region;
- transformed Melody source-note step and MIDI values.

Runtime randomness, `Hasher`, `Date`, and new UUID generation are not used.

Raw `vibePosition` is not hashed. However, transformed Melody MIDI values depend on rounded register shift. Crossing a register-shift threshold can therefore change the seed and rebuild the motif even inside the same region. This is a current known behavior.

### Groove selection

The Vibe quadrant selects Airy, Bright, Deep, or Intense.

Each region has three hard-coded 16-step variants. Variant index is derived from FNV-1a hashing of sorted active assigned UUID strings, so the same active assignment set and region produce the same pattern.

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

Jam playback is one native looping rendered buffer at 96 BPM. Visible transport is derived from the live audio node rather than an independent clock.

While playing:

- Vibe, role assignment, Arrange, and Drum Kit changes build the newest candidate arrangement;
- `MusicPlayer` owns render debouncing, cancellation, and next-loop buffer scheduling;
- `JamPlaybackController` tracks the pending arrangement, the loop iteration at request time, preparation feedback, and the applied arrangement version;
- only the latest prepared replacement is eligible to become active;
- the UI promotes it after transport wrap and then emits success/selection feedback;
- effect parameter changes apply directly to the effect chain and are not quantized through arrangement rendering.

## Persistence

Application Support currently contains two independent local stores:

```text
Dap/
├── library.json
├── Covers/
│   └── <Photo UUID>.png
└── Jams/
    └── <Jam UUID>.json
```

Generated Jam Covers are deterministic derivatives rendered and cached in memory by `JamCoverRenderer`; they are not persisted as separate files.

### Musical Photo save contract

1. create directories;
2. write Cover PNG;
3. prepend and newest-sort the updated library;
4. atomically write `library.json`;
5. remove the new Cover if the JSON write fails;
6. publish memory state only after full persistence success.

### Musical Photo metadata patch contract

Metadata updates read, modify, and atomically rewrite the library inside one `PhotoStore` actor turn. Name, `nameSource`, and description are the only mutable metadata fields. Generated updates can preserve a manual name.

### Musical Photo delete contract

`PhotoStore.delete` temporarily moves the Cover aside, atomically writes the reduced library, restores the Cover if the JSON write fails, and removes the stashed Cover only after success.

Deleting a Musical Photo does not rewrite every Saved Jam immediately. Open Jam sessions prune invalid UUIDs against the current shared library and autosave the cleaned assignments.

### Saved Jam contract

`JamStore` is an actor. It:

- stores one pretty-printed, sorted-key JSON file per Jam;
- validates `PersistedJam.currentSchemaVersion == 1`;
- normalizes names to a non-empty maximum of 80 characters;
- relies on persisted/runtime conversion helpers to clamp Vibe coordinates and effect values when Jam state is applied or snapshotted;
- removes duplicate UUID assignments during sanitization;
- updates `updatedAt` on save;
- lists documents newest-updated-first;
- ignores corrupted or unsupported files during listing while logging them.

`JamView` schedules autosave after a 500 ms debounce for document changes and flushes pending state on close/background lifecycle paths. Rendered arrangements, generated backdrop snapshots, transport state, pending loop buffers, and audio DSP phase are never persisted.

### Current persistence gaps

The app does not persist:

- original Source Images;
- manual Gallery ordering or grouping;
- rendered Jam arrangements or audio buffers;
- generated Jam Cover PNG files;
- export history;
- algorithm-version metadata for Musical Photos;
- migration logic beyond strict Saved Jam schema-version rejection.

## Module ownership

### `DapApp`

Creates `AppRootView`.

### `AppRootView`

Owns root section, Gallery path, Capture presentation, Jam-session visibility, root chrome, deferred App Intent routing, and shared `PhotoLibraryViewModel` lifetime.

### `DapAppShortcuts` / `DapPendingActionStore`

Own App Shortcut declarations and the one-shot persisted request used to bridge an App Intent into active root presentation state.

### `DapFont`

Owns the reusable ZT Talk weight mapping and Dynamic Type-relative SwiftUI font helpers. Font registration remains in `Info.plist`.

### `PhotoLibraryViewModel`

Owns in-memory Musical Photo items, Cover cache, import state, metadata task coordination, shared playback façade, Jam effect forwarding, transport snapshot access, and loop-prepared callback plumbing.

Despite its name, it is shared by Gallery, Capture, Inspector, and Jam.

### `PhotoStore`

Owns Musical Photo JSON, Cover files, serialized saves, metadata patches, rollback-safe deletion, and Cover loading.

### `PhotoMusicPipeline`

Owns deterministic image analysis, base Musical Sequence construction, Musical Identity, and Cover generation.

### `RetroCoverRenderer`

Owns canonical pitch colors, tonal palettes, pattern halftone, Floyd-Steinberg analysis rendering, and pixel-level helpers.

### `PhotoMetadataGenerator`

Owns Vision classification, Foundation Models prompting, guided output, sanitization, and graceful failure.

### `MusicPlayer`

Owns the single audio engine, player nodes, Jam effect chain, scheduling, replacement cancellation, transport introspection, audio-session lifecycle, and interruptions.

### `JamAudioRenderer`

Owns detached offline tonal and percussion rendering, role-based stems, Future Bass, sample playback, pumping, mixing, and procedural fallbacks.

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

Owns one-Photo presentation, share/delete actions, playback controls, and the Add-to-Jam picker flow.

### `JamLibraryView` / `JamLibraryState`

Own Jam-library presentation and observable library workflow state: loading, filtering, draft creation, selection, rename, delete, and save coordination.

### `JamStore`

Owns Saved Jam JSON schema validation, sanitization, listing, creation, loading, saving, rename, and deletion.

### `JamView`

Owns one open Jam session's orchestration: applying persisted state, routing UI actions, arrangement rebuild requests, autosave, lifecycle teardown, panel presentation, and coordination between narrow state owners.

### `JamSessionState`

Owns current document values: Jam identity/name/date, slot assignments, role variations, Vibe, Drum Kit, effects, active arrangement, and play intent.

### `JamPlaybackController`

Owns pending replacement arrangement state, loop-boundary promotion, Drum Kit pending feedback, and applied-arrangement versioning.

### `JamVisualTransportState`

Owns only the visible current step and active Photo UUIDs projected from the live audio transport.

### Jam presentation components

- `JamPhotoSection`: role tiles, drag/drop, selection, and Photo presentation;
- `JamSequencerSection`: sequencer and transport/status presentation;
- `JamDockBar`: compact panel launch controls;
- `JamControlPanels`: Kits, Vibe, Arrange, and Effects panel UI;
- `JamPanelBackdrop`: rasterizable frozen session backdrop used behind expanded panels;
- `JamPhotoSelectorSheet`: bounded Photo membership selection.

### `JamArrangementBuilder`

Owns initial role assignment, global harmony, Vibe interpolation, Bass/Harmony transformation, contextual role variations, Melody Motif Engine, and active-step attribution.

### `JamGrooveLibrary`

Owns groove-region classification, stable set hashing, and the twelve hard-coded percussion variants.

### `JamCoverRenderer`

Owns deterministic abstract Jam artwork, recipe versioning, detached rendering, in-memory cache, and in-flight request deduplication.

## Domain invariants

1. Every successfully persisted Musical Photo has one stable UUID.
2. The essential Musical Photo and Cover persist before shared memory publishes the item.
3. Metadata is optional and never changes the Cover or Musical Sequence.
4. Generated metadata must not overwrite a manual Photo name when preservation is requested.
5. The original Source Image is not part of the persisted Musical Photo today.
6. Gallery reads Covers from the shared in-memory cache, not from disk during view rendering.
7. The persisted Musical Photo library is newest-first.
8. One shared `MusicPlayer` arbitrates all playback and global Jam DSP.
9. Starting a non-looping playback path stops the previous path.
10. A running Jam loop receives replacement arrangements through latest-wins next-loop scheduling rather than a second engine.
11. Visible Jam transport is derived from the live Jam player node.
12. Capture acquires Source Images but does not own persisted library state.
13. Inspector presents an existing Musical Photo and does not duplicate it.
14. The root pitch class is the canonical source for pitch-color identity.
15. Photo creation, Jam arrangement, role variations, grooves, and Jam Covers are deterministic for stable inputs and current algorithms.
16. A Saved Jam references Musical Photos by stable UUID and never mutates persisted Photo sequences.
17. `JamSlotAssignments` is the sole membership and role source for an open Jam.
18. Initial role sorting runs only to establish an assignment; later swaps preserve explicit role state.
19. Only the Photo assigned `.melody` supplies the current primary Melody note pool.
20. All active assigned Photos contribute to global Jam harmony.
21. Melody and Harmony samples are role-specific Jam behavior; nil-role Photo playback remains procedural.
22. Drum Kit selection changes instrumentation, not the underlying regional groove pattern.
23. Global Jam effects alter playback DSP and persist as settings; they do not rewrite the arrangement.
24. Rendered arrangements, buffers, transport projections, panel snapshots, and DSP phase are transient.
25. Saved Jam schema version is validated before use; unsupported versions are not silently migrated.
26. The current product limit is three Photos per Jam.
27. Melody has no per-note duration model; timing offsets are currently used only where explicitly generated, such as Bass variation timing.

## Current intentional gaps and risks

The following are not implemented and must not be assumed to exist:

- persisted per-Photo effects;
- Studio mode;
- export of audio, MIDI, video, animations, or Instagram Stories;
- Gallery multi-selection, grouping, and manual reordering;
- persisted original Source Images;
- cloud sync;
- multiplayer or collaboration;
- remote services;
- analytics;
- a test target;
- Saved Jam schema migration beyond rejecting unsupported versions.

Current technical or musical risks:

- Bass, Harmony, and Melody variation generation still requires broad listening validation across intents, grooves, Vibe regions, and Photo sets;
- Melody variation search is intentionally complex and can fall back when no candidate meets the requested difference threshold;
- Melody A/A' identity can change at rounded register-shift thresholds because transformed MIDI values enter the seed;
- additional selected Photos alter Melody context and seed but do not contribute equal Melody pitch material;
- pumping is not circular across the loop boundary;
- there is no per-note duration model for Melody articulation;
- final output uses clamping rather than a dedicated limiter/master stage;
- Saved Jams can retain UUID references to deleted Photos until loaded/reconciled and saved;
- Jam Cover cache is in-memory only and can rerender after relaunch;
- the panel backdrop is a rasterized UI snapshot and must remain separated from live sequencer transport to avoid stale animation;
- the project has no automated regression coverage for persistence, audio scheduling, or complex Jam UI state.

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
- whether future Musical Photo algorithm versions regenerate existing content;
- how Musical Photo or Saved Jam schema migrations should work;
- whether effects should also belong to individual Photos;
- whether Jam BPM becomes variable;
- whether Vibe groove regions retain hard quadrant boundaries;
- whether Melody should borrow equal note material from non-Melody Photos;
- whether Jam should support more than three Photos and what reserve means beyond current reconciliation;
- whether bundled Bass samples should replace or complement Future Bass;
- how deleting a Photo should proactively affect every Saved Jam;
- whether generated Jam Covers should ever be persisted or exported;
- how Gallery multi-selection, grouping, and ordering should work;
- exact export formats, Story integration, audio/video rendering, and animation system;
- what Studio means as an interaction and data model;
- whether App Shortcuts should gain parameters, entities, or background-capable actions.

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
