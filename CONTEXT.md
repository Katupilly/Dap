# Dap Domain Context

This file defines Dap's shared domain language, invariants, ownership, and current scope.

Read it before changing the domain model or introducing a new module. It is not an implementation spec: features still require authorization from the current spec or an accepted ADR.

## Product definition

Dap turns a photo into a playable musical object and lets the user combine musical photos inside a Jam.

Product principles:

- The photo is the creative starting point.
- The first playable result should feel immediate.
- Optional AI enrichment must never block creation.
- Simple interaction comes before advanced editing.
- Musical Photos, Effects, and Jams are distinct domain concepts.

## Domain glossary

### Musical Photo

The saved creative object generated from one captured or imported image.

It currently contains:

- a stable UUID;
- creation date;
- generated Cover;
- Musical Sequence;
- optional generated name and description.

The current code symbol is `PhotoSound`. Product language and documentation should prefer **Musical Photo** or **Photo**. Do not rename the symbol opportunistically; rename it only as an intentional scoped change.

A Musical Photo is not an Effect and must not be called a pedal.

### Source Image

The image data received from the camera or Photos picker before processing.

The current implementation treats it as transient. Dap persists the generated Cover and musical data, not the original image. Do not assume the original is available later unless a future spec changes this.

### Photo Creation

The complete transformation from Source Image to saved Musical Photo:

1. decode and normalize the image;
2. analyze visual properties;
3. generate the retro image;
4. generate the Musical Sequence;
5. recolor the Cover from its tonal identity;
6. persist the essential result;
7. optionally refine its metadata.

The essential result is the Cover plus Musical Sequence. Metadata is enrichment.

### Cover

The generated retro visual displayed in Gallery and Photo Inspector.

The current Cover is a four-tone, 2-bit rendering recolored from the dominant pitch class. It is persisted as PNG data. It is derived media, not the Source Image.

### Musical Sequence

The playable representation derived from image analysis.

It currently contains:

- a 16-step by 8-row note grid;
- root pitch class and scale;
- BPM;
- note velocity;
- gate and octave range;
- waveform.

For the same normalized image and algorithm version, the Musical Sequence and Cover should remain deterministic. UUIDs, timestamps, and generated metadata are excluded from this guarantee.

### Musical Identity

The properties that make one Musical Photo recognizable: root, scale, BPM, waveform, and dominant pitch class.

The dominant pitch class also selects the Cover palette, intentionally connecting visual and musical identity.

### Metadata

The optional generated name and description.

Metadata refinement occurs after the essential Musical Photo is saved. Failure, cancellation, model unavailability, or guardrail rejection must leave the Photo usable.

A metadata update may change only `name` and `description`. It must preserve identity, creation date, Cover reference, and Musical Sequence.

### Gallery

The user's canonical collection of saved Musical Photos.

Gallery browses and opens Photos. Its views do not own persistence and must not perform synchronous disk I/O while rendering.

### Photo Inspector

The detail surface for one Musical Photo.

It presents the Cover, metadata, Musical Identity, playback, and future actions such as adding Effects or adding the Photo to a Jam. It is not a separate persisted entity.

### Playback

The local audio rendering of a Musical Sequence.

The current application has one shared active playback state. Starting another Musical Photo stops the previous one. UI features must not create independent audio-engine owners.

### Effect

An audio transformation such as reverb, distortion, delay, or filtering.

Effects are the concepts that may use pedal-like visual language. A Musical Photo itself is not a pedal.

Planned scopes:

- **Photo Effect** — previewed or applied to one Musical Photo;
- **Global Jam Effect** — applied to the combined Jam output.

Do not assume Photo Effects are inherited by Jam. Current product direction keeps Jam effects global. Persistence rules for Photo Effects remain undecided.

### Jam

A playable session that combines multiple Musical Photos under shared musical and effect controls.

A Jam references existing Photos by stable identity. It does not duplicate ownership of their Covers, Musical Sequences, or metadata.

The first Jam implementation is local and centered on Vibe.

### Vibe

The simple, default interaction mode inside Jam.

Vibe uses a spatial control to shape shared musical behavior with minimal setup. It is a Jam mode, not another top-level domain.

The exact coordinate-to-music mapping requires a dedicated spec.

### Studio

A future advanced Jam mode for explicit arrangement and connections between Photos.

Studio is deferred. Do not introduce Studio models, graph structures, canvas architecture, or navigation before a current spec authorizes them.

## Core workflows

### Create a Musical Photo

`Camera or Photos → Source Image → Photo Creation → PhotoStore → Gallery`

The Photo appears after the essential result is persisted. Metadata may refine afterward.

Capture is a full-screen workflow. A successful shutter capture keeps Capture presented, returns it to its ready state, and updates the Gallery thumbnail from shared library state. The user exits Capture only by tapping the Gallery thumbnail.### Inspect and play

`Gallery → Photo Inspector → shared Playback`

Photo Inspector acts on the existing Musical Photo and shared playback state.

### Create a Jam — planned first slice

`Gallery Photos → Jam → Vibe → shared playback and Global Jam Effects`

This is product direction, not authorization to implement all steps at once.

## Domain invariants

1. A successfully created Musical Photo has one stable UUID.
2. Creation succeeds only after its Cover and essential musical data are persisted.
3. Metadata never determines whether creation succeeded.
4. Metadata never changes the Cover or Musical Sequence.
5. Gallery renders from in-memory state; storage reads remain behind persistence.
6. The persisted library is newest-first until a spec defines user ordering.
7. Only one Musical Photo plays at a time in the current application.
8. Capture acquires Source Image data but does not own the persisted library.
9. Photo Inspector presents a Musical Photo but does not duplicate it.
10. A Jam references Photos by stable identity.
11. Musical Photos and Effects remain distinct models.
12. Vibe and Studio remain modes inside Jam.

## Current module ownership

### `AppRootView`

Owns root presentation state, the selected root section, Capture presentation, root chrome, and the shared `PhotoLibraryViewModel` instance.

It must not absorb photo processing, persistence, or audio rendering.

### `PhotoLibraryViewModel`

The current shared application-state module for Gallery and Capture.

It owns:

- in-memory Photos;
- in-memory Cover cache;
- import and metadata-refinement state;
- shared playback state;
- coordination between processing, persistence, enrichment, and playback.

Despite its name, it is not private to a single view. Do not create another owner for the same library state.

### `PhotoStore`

Owns persisted library state under Application Support:

- `library.json`;
- Cover PNG files;
- atomic writes;
- metadata patches;
- Cover-data loading;
- serialized persistence through its actor.

Callers should not reproduce its read-modify-write behavior.

### `PhotoMusicPipeline`

Owns deterministic visual and musical derivation:

- image normalization;
- visual analysis;
- sequence construction;
- retro Cover generation;
- tonal recoloring.

It does not own persistence, UI state, metadata generation, or playback.

### `PhotoMetadataGenerator`

Owns best-effort visual classification, Foundation Models generation, sanitization, and graceful failure.

It does not decide whether a Photo is saved.

### `RetroCoverRenderer`

Owns dithering, tonal palettes, recoloring, and pixel-level rendering. Keep this implementation local behind its small interface.

### `MusicPlayer`

Owns `AVAudioEngine`, note rendering, buffers, playback completion, and interruption details behind play and stop operations.

### `CameraView` and `CameraController`

`CameraView` owns presentation and capture interaction. `CameraController` hides `AVCaptureSession`, preview, rotation, and capture details.

Do not split the controller only because the file is large.

### `GalleryView`

Owns Gallery layout and navigation to Photo Inspector. It does not own processing, persistence, metadata generation, or audio implementation.

### `PhotoInspectorView`

Owns the detail presentation for one Musical Photo. Effect and Jam actions remain placeholders until specified.

### `JamView`

Currently a placeholder. Do not infer future architecture from it. Start with the smallest local Vibe vertical slice once specified.

## Ownership rules and seams

- Camera and PhotosPicker produce Source Image data.
- Photo Creation transforms Source Image data into a Musical Photo.
- `PhotoStore` persists and reloads the library.
- Shared library state publishes Photos and coordinates user-facing operations.
- Gallery browses Photos.
- Photo Inspector acts on one existing Photo.
- `MusicPlayer` renders Musical Sequences.
- Jam owns Jam-specific state and references Photos.
- Effects own audio transformation parameters, not Photo identity.

Across feature seams, prefer stable IDs or small Sendable snapshots. Do not pass filesystem URLs, audio-engine internals, camera-session objects, or mutable persistence collections through views.

## Naming rules

Use:

- **Musical Photo** or **Photo** for the saved photo-derived object;
- **Source Image** for raw imported or captured image data;
- **Cover** for the generated visual;
- **Musical Sequence** for playable note data;
- **Effect** for an audio transformation;
- **Jam** for the multi-photo session;
- **Vibe** and **Studio** only as Jam modes;
- **Photo Inspector** for the Photo detail surface.

Avoid:

- `Pedal` for a Musical Photo;
- `Pedalboard` for a Jam;
- `Session` without a qualifier;
- `Manager`, `Coordinator`, or `Service` when a precise domain name exists;
- `Engine` unless the module encapsulates an actual runtime engine.

Existing symbols such as `PhotoSound`, `ProcessedPhotoSound`, and `PhotoLibraryViewModel` may remain until an explicit rename. New product copy and documentation should use the domain language above.

## Architecture guardrails

- Prefer a few deep modules with small interfaces over many shallow wrappers.
- Preserve locality: behavior required to understand one operation should stay close together.
- Apply the deletion test before extracting a module.
- One adapter is a hypothetical seam; add an abstraction when two real implementations or a proven testing need make it real.
- Do not add protocols solely for dependency injection.
- Do not add a repository wrapper around `PhotoStore` without a concrete second persistence implementation.
- Do not introduce a navigation coordinator while navigation remains small and concrete.
- Do not split `CameraController`, `MusicPlayer`, or `RetroCoverRenderer` only to reduce file length.
- Keep disk I/O, Vision, image processing, model generation, and audio rendering out of SwiftUI `body` evaluation.
- Keep non-Sendable framework objects inside their owning modules and cross concurrency boundaries with Sendable values.
- Avoid duplicated state that represents the same truth.

## Current scope

- Gallery;
- camera and Photos import;
- deterministic photo-to-music creation;
- progressive metadata;
- Photo Inspector;
- shared single-photo playback;
- the first local Vibe slice when specified.

## Deferred scope

Do not prebuild architecture for:

- Studio;
- multiplayer or Game Center synchronization;
- remote collaboration;
- cloud persistence;
- graph-based Photo connections;
- advanced arrangement timelines;
- trained generative-music models;
- generic plugin systems;
- multiple persistence backends.

Deferred means the current code should not pay their architectural cost yet.

## Decisions requiring a spec or ADR

Do not guess:

- whether the original Source Image will be persisted;
- whether Photo Effects are persisted;
- whether Photo Effects influence Jam;
- the Vibe coordinate-to-music mapping;
- the persisted shape and lifecycle of a Jam;
- behavior for missing or deleted Photos in a Jam;
- multiplayer authority and disconnect behavior;
- user-controlled Gallery ordering;
- migration rules for future algorithm versions.

## Change checklist

Before adding or moving code, answer:

1. Which domain concept owns this behavior?
2. Does the change improve locality?
3. Is the proposed module deep or shallow?
4. Is the seam real today or hypothetical?
5. Does it preserve the invariants above?
6. Is it authorized by current scope, a spec, or an ADR?
7. Does its terminology match this glossary?

Update this file when domain language or invariants change. Do not use it as a changelog.
