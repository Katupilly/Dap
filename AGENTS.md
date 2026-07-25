# AGENTS.md

## Project Overview

Dap is an experimental iOS application that transforms photos into musical material.

The application focuses on four primary experiences:

* Capture or import photos.
* Browse saved photos in the Gallery.
* Inspect and modify the musical properties of a photo.
* Combine multiple photos inside Jam sessions.

The project is in an early product-development stage. Optimize for clarity, iteration speed, native platform behavior, and low maintenance cost.

Do not optimize for hypothetical scale.

---

## Core Principles

1. Prefer the smallest implementation that correctly supports the current product requirement.
2. Use native Apple frameworks whenever they provide an adequate solution.
3. Keep the number of files, layers, abstractions, and dependencies low.
4. Maintain a single source of truth for every piece of application state.
5. Implement working vertical slices before creating generalized infrastructure.
6. Preserve existing behavior unless the task explicitly requests a change.
7. Do not introduce visual or architectural decisions that were not requested.
8. Avoid speculative work for future features.
9. Make code understandable to a small product team.
10. Prefer direct code over clever code.

---

## Platform and Technology

* Platform: iOS
* UI framework: SwiftUI
* Language: Swift
* Architecture: pragmatic MVVM
* Audio: AVFoundation and AVAudioEngine
* Photo access: PhotosUI and PhotoKit when necessary
* Camera: native Apple camera APIs
* On-device generation: Foundation Models framework
* Persistence: simple local persistence appropriate to the current data model

Use UIKit only when SwiftUI cannot reasonably deliver the required behavior or performance.

Do not introduce third-party dependencies unless explicitly approved.

---

## Architecture

Use a lightweight feature-oriented structure.

Recommended baseline:

```text
Dap/
├── App/
│   ├── DapApp.swift
│   └── AppRootView.swift
│
├── Features/
│   ├── Gallery/
│   ├── Capture/
│   ├── Inspector/
│   └── Jam/
│
├── Shared/
│   ├── Models/
│   ├── Audio/
│   ├── ImageProcessing/
│   ├── Persistence/
│   └── Components/
│
└── Resources/
```

This structure is a guideline, not a requirement to create empty folders or placeholder files.

Only create a directory when it contains code that is currently needed.

---

## MVVM Guidelines

Use MVVM pragmatically.

A feature may contain:

```text
FeatureView.swift
FeatureViewModel.swift
FeatureModel.swift
```

Not every screen requires a ViewModel.

Keep state directly in a SwiftUI View when:

* The state is local to the presentation.
* The logic is small.
* The state does not need to be shared.
* Extracting it would only add indirection.

Create a ViewModel when:

* The screen coordinates meaningful business logic.
* The state has multiple transitions.
* The logic interacts with persistence, audio, image processing, or Foundation Models.
* The logic should survive view reconstruction.
* The View has become difficult to understand.

Do not create ViewModels that merely rename properties or forward method calls.

---

## State Management

Every state must have one clear owner.

Do not mirror the same state across multiple Views or ViewModels.

Prefer:

* Value state for local UI state.
* `@Observable` models for shared mutable feature state.
* Bindings when a child View needs to mutate state owned by its parent.
* Derived properties for values that can be calculated from existing state.

Avoid synchronization code between duplicated state, including unnecessary `onChange` callbacks.

Do not create global state unless the value is truly application-wide.

Navigation state should have one explicit owner.

---

## Navigation

Keep navigation native and predictable.

Prefer:

* `NavigationStack`
* Typed navigation paths
* Native sheets
* Native full-screen covers
* Native tab or segmented navigation when appropriate

Do not build custom navigation infrastructure unless the product requirement cannot be achieved with native APIs.

Do not create:

* Coordinators
* Routers
* Navigation orchestrators
* Navigation service protocols

A custom navigation abstraction requires explicit approval.

When changing navigation:

1. Preserve existing screen behavior.
2. Preserve back navigation.
3. Preserve interactive gestures where possible.
4. Verify the visibility of headers, controls, and bottom chrome.
5. Avoid duplicated route and presentation state.

---

## SwiftUI Guidelines

Prefer straightforward SwiftUI composition.

A View should communicate its structure clearly.

Extract a subview when:

* It represents a meaningful visual component.
* It is reused.
* It has independent state or behavior.
* Extraction substantially improves readability.

Do not split Views into many tiny files solely to reduce line count.

Prefer private computed Views or private subviews in the same file for small, screen-specific elements.

Avoid unnecessary:

* `AnyView`
* Type erasure
* Preference keys
* Geometry readers
* Custom layout systems
* Environment values
* View modifiers with only one usage
* Wrapper components around native controls

Use these tools only when they solve a demonstrated requirement.

---

## Design Fidelity

The supplied design and requested behavior are the source of truth.

Do not modify the visual direction without approval.

Do not add unrequested:

* Blur
* Gradients
* Shadows
* Materials
* Animations
* Haptics
* Transitions
* Decorative backgrounds
* Floating controls
* Glass effects
* Additional labels
* Additional navigation elements

Do not reinterpret wireframes as permission to redesign the screen.

When a design detail is unspecified, prefer a simple native presentation.

Preserve existing spacing, hierarchy, interaction, and animation unless the task explicitly changes them.

---

## Animation

Use native SwiftUI animation APIs.

Animations should:

* Communicate state changes.
* Preserve spatial continuity.
* Avoid delaying interaction.
* Respect Reduce Motion.
* Remain deterministic and easy to understand.

Do not add animation purely for decoration.

For hero transitions or matched geometry:

* Keep one clear source and one clear destination.
* Avoid duplicate matched geometry identifiers.
* Keep transition state owned by the nearest common ancestor.
* Do not use delayed state synchronization as a layout fix.
* Verify tap, back button, and interactive-dismiss paths separately.

Do not replace an existing transition with a different implementation unless requested.

---

## Accessibility

All interactive controls must have appropriate accessibility labels.

Add hints only when the action is not evident from the label.

Consider:

* VoiceOver
* Dynamic Type
* Reduce Motion
* Sufficient tap targets
* Logical focus order
* Button traits
* Selected states

Accessibility must not require a parallel UI implementation.

Prefer native controls because they provide better accessibility behavior by default.

---

## Feature Boundaries

### Gallery

Gallery owns:

* Displaying saved photos.
* Photo grouping and ordering.
* Navigation to the Photo Inspector.
* Import entry points when present in the approved flow.

Gallery should not own:

* Audio synthesis.
* Foundation Models prompts.
* Jam session coordination.
* Effect-processing internals.

### Capture

Capture owns:

* Camera presentation.
* Photo capture.
* Photo import when part of the approved flow.
* Capture-specific controls and state.
* Preparing a captured image for the next application step.

Capture should not duplicate Gallery persistence logic.

### Photo Inspector

Photo Inspector owns:

* Displaying one selected photo.
* Displaying its musical identity.
* Previewing playback.
* Managing effects associated with that photo.
* Actions related specifically to that photo.

Photo-specific effects belong to the photo.

They should not automatically become global Jam effects.

### Jam

Jam owns:

* Combining multiple photos.
* Session-level playback.
* Session-level musical coordination.
* Global Jam effects.
* Vibe and Studio presentation when implemented.

Implement Vibe before Studio unless the task explicitly says otherwise.

Do not implement multiplayer, collaboration, advanced canvases, or speculative session infrastructure before those features are requested.

---

## Music and Audio

Keep deterministic music generation separate from presentation code.

Views must not contain:

* Pixel analysis.
* Scale-selection algorithms.
* MIDI generation.
* Audio graph construction.
* Playback scheduling logic.

Audio ownership must be explicit.

Avoid multiple independent playback engines unless the feature requires them.

Playback state should clearly represent states such as:

```swift
enum PlaybackState {
    case stopped
    case playing
    case paused
}
```

Do not introduce a generalized audio framework for a single concrete playback flow.

Prefer concrete services such as:

```swift
@Observable
final class PhotoPlaybackEngine {
    // Concrete implementation
}
```

Do not create protocols solely for dependency injection.

---

## Image Processing

Image processing must remain outside SwiftUI View bodies.

Do not perform expensive image work synchronously during rendering.

Image-processing operations should:

* Accept explicit inputs.
* Produce explicit outputs.
* Avoid hidden global state.
* Preserve orientation correctly.
* Avoid repeated full-resolution decoding.
* Support cancellation when the operation may outlive the screen.

Do not create a complex processing pipeline before multiple processing stages actually require one.

---

## Foundation Models

Use Foundation Models for tasks where generative interpretation adds meaningful product value.

Appropriate examples include:

* Generating a playful photo name.
* Generating a short musical description.
* Interpreting visual mood into constrained metadata.
* Producing labels or creative text from deterministic musical results.

Do not rely on Foundation Models for deterministic application rules.

Deterministic logic should remain responsible for:

* Pitch selection.
* Scale calculation.
* MIDI timing.
* Playback scheduling.
* Persistence identifiers.
* File paths.
* Data migrations.
* Core navigation.

Foundation Models output must be treated as optional and fallible.

Always provide a usable fallback when generation:

* Is unavailable.
* Fails.
* Is cancelled.
* Produces invalid output.
* Takes longer than the current flow permits.

Do not create multiple abstraction layers around a single Foundation Models session.

A concrete service is preferred.

---

## Persistence

Use the simplest persistence mechanism that safely supports the current data.

Requirements:

* Data ownership must be clear.
* Writes must avoid leaving corrupted partial files.
* Models should have an explicit version when persisted long-term.
* Missing optional data should degrade gracefully.
* UI rendering must not perform repeated disk access.

Do not introduce:

* Repository layers
* Database abstractions
* Cloud synchronization
* Migration frameworks
* Generic storage protocols

unless the current feature explicitly requires them.

Do not create persistence infrastructure for unimplemented future models.

---

## Concurrency

Use Swift concurrency where asynchronous work is real.

Prefer:

* `async` functions
* Structured concurrency
* Task cancellation
* Main-actor UI state
* Actors only for genuinely shared mutable state

Do not add concurrency to synchronous operations without a concrete reason.

Do not create actors as architectural decoration.

Avoid:

* Detached tasks without clear ownership
* Fire-and-forget tasks
* Unstructured background work
* Duplicated tasks triggered by View reconstruction
* Manual dispatch queues when Swift concurrency is sufficient

UI state mutations must occur on the appropriate actor.

---

## Error Handling

Handle errors at the level where the application can make a meaningful decision.

The user-facing UI should distinguish between:

* Empty state
* Loading state
* Recoverable failure
* Unavailable resource
* Permanent unsupported condition

Do not silently swallow errors that affect visible behavior.

Do not expose raw internal error descriptions directly to users.

Debug logs should provide enough context to identify:

* The operation
* The affected model identifier
* The failure category

Avoid noisy logging inside frequently recomputed SwiftUI code.

---

## Testing Policy

Do not add automated tests unless explicitly requested.

Do not create:

* Test targets
* Test fixtures
* Mock services
* Snapshot tests
* UI tests
* Test-only protocols
* Testing documentation

unless the task specifically requires them.

A deterministic or high-risk domain rule may justify suggesting tests, but do not implement them without approval.

Do not restructure production code solely to make it testable when tests are not part of the task.

---

## Validation

Validation must be proportional to the change.

For normal implementation work:

1. Build the application.
2. Resolve compiler errors and warnings introduced by the change.
3. Run the affected flow in the Simulator when possible.
4. Check for obvious runtime failures.
5. Report the exact visual or interaction points that require designer validation.

For visual changes, verify:

* Layout
* Safe areas
* Navigation chrome
* Bottom controls
* Loading states
* Empty states
* Back navigation
* Sheet dismissal
* Interactive gestures
* Reduce Motion behavior when relevant

Do not create additional validation documents.

Do not claim a flow was visually verified when it was only compiled.

Clearly distinguish:

* Build verification
* Simulator verification
* Device verification
* Designer verification

---

## Prohibited Patterns

Do not introduce the following unless explicitly requested:

* Clean Architecture
* VIPER
* Coordinators
* Interactors
* Use cases
* Orchestrators
* Repository patterns
* Service locators
* Dependency-injection containers
* Generic feature frameworks
* Event buses
* Redux-style global stores
* Protocols with only one conforming type
* Factories with only one product
* Builders for simple models
* Generic persistence layers
* Premature modularization
* Speculative caching
* Speculative multiplayer infrastructure
* Placeholder architecture for future features

Do not add a new abstraction merely because it may become useful later.

---

## Code Changes

Keep changes focused on the requested task.

Do not:

* Refactor unrelated code.
* Rename unrelated symbols.
* Reformat entire files.
* Move files without a concrete need.
* Replace working APIs solely based on personal preference.
* Delete existing functionality that is outside the task.
* Introduce unrelated visual changes.
* Change product copy without approval.
* Add new dependencies without approval.

Before editing, identify the smallest set of files required.

When an existing implementation is flawed, prefer a localized correction before a broad rewrite.

---

## File Creation

Every new file must have a current purpose.

Do not create:

* Empty folders
* Placeholder files
* Future-facing protocols
* Documentation for features that do not exist
* Duplicate models
* Convenience files containing a single trivial extension
* Separate files for tiny private subviews

Prefer adding a small amount of related code to an existing feature file when that remains readable.

---

## Working With the Designer

The designer is actively validating the product during implementation.

When completing a task, report:

1. What changed.
2. Which files changed.
3. Which state owns the new behavior.
4. Any behavior intentionally preserved.
5. What was validated technically.
6. What still requires visual validation.

When a decision materially affects UX, explain the tradeoff before choosing a complex solution.

Examples include:

* Changing navigation behavior.
* Removing interactive dismissal.
* Replacing a native control.
* Changing animation structure.
* Moving actions between screens.
* Changing whether data is saved automatically.
* Changing the ownership of photo or Jam effects.

Do not make product decisions silently.

---

## Implementation Style

Write code as a senior iOS developer working closely with a product designer.

The implementation should be:

* Small
* Direct
* Native
* Readable
* Focused
* Easy to remove or change
* Appropriate for the current product stage

Prefer concrete names tied to the product domain.

Good:

```swift
PhotoInspectorView
JamSession
PhotoPlaybackEngine
GalleryViewModel
CapturedPhoto
GlobalJamEffects
```

Avoid vague infrastructure names:

```swift
Manager
Handler
Coordinator
Processor
Helper
Orchestrator
EngineServiceProvider
```

Use comments only when they explain a non-obvious constraint or product decision.

Do not comment code that is already self-explanatory.

---

## Completion Format

At the end of an implementation task, provide a concise report using this structure:

```text
Implemented
- Summary of the completed behavior.

Files changed
- Path/File.swift
- Path/OtherFile.swift

State ownership
- Identify the source of truth.

Preserved behavior
- List important behavior that was intentionally kept unchanged.

Validation
- Build:
- Simulator:
- Device:
- Visual review:

Notes
- Relevant limitations or product decisions.
```

Do not include a long narrative unless the change requires deeper explanation.

---

## Final Rule

This project should remain smaller than the problem it solves.

When choosing between two valid implementations, prefer the one with:

* Fewer concepts
* Fewer files
* Fewer state owners
* Fewer synchronization points
* Fewer dependencies
* More native platform behavior

Complexity must be earned by a concrete product requirement.
