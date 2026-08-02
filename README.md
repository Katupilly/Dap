# Dap

**Turn photos into playable music.**

Dap is an iPhone musical toy that transforms photos into notes, rhythms, and playable sequences. It is designed for people who want to create music without needing to understand music theory first.

A photo is not treated only as something to look at. In Dap, it becomes an instrument connected to a memory.

## The idea

Music creation often begins with technical concepts: scales, harmony, rhythm, sequencing, and sound design. For someone who is not a musician, that can become the first barrier.

Dap starts from a gesture almost everyone already understands: taking a photo.

The app analyzes visual information such as color, contrast, and tonal relationships, then translates it into musical material. The system is inspired by relationships between the chromatic circle, the circle of fifths, and color theory.

## How it works

1. **Capture or import a photo**  
   Begin with an image from a moment, place, person, object, or texture.

2. **Translate color into music**  
   Dap maps visual relationships into notes and tonal material.

3. **Generate a sequence**  
   Each photo creates a repeatable 16-step musical pattern.

4. **Play and remix**  
   Listen to a photo individually or combine multiple photos inside a Jam.

## Core features

- Capture photos directly in the app
- Import images from the photo library
- Generate notes and rhythms from image color and tone
- Play each photo as an individual instrument
- Combine multiple photos inside a **Jam**
- Automatically assign bass, harmony, and melody roles
- Explore musical moods through the **Vibe** control
- Add drum kits, reverb, delay, and rhythmic modulation
- Export and share generated photo covers
- Use Siri and Shortcuts through App Intents
- Generate photo names and descriptions with Apple Foundation Models on supported Apple Intelligence devices

## Design principles

### Photos before theory

The experience begins with a familiar visual action instead of a musical abstraction. Users create through images first and discover the musical system through play.

### Play before configuration

Dap is a musical toy rather than a traditional production tool. The first interaction should produce a meaningful result without requiring setup.

### Immediate feedback

Sound, motion, and haptics work together so that every action feels responsive and intentional.

### Memories as instruments

Photos become active material that can be replayed, combined, and transformed instead of remaining static records.

## Technology

Dap is built natively for iPhone with:

- **SwiftUI** for interface and interaction design
- **AVAudioEngine** for synthesis, sequencing, looping, and real-time effects
- **Core Image** and custom image analysis for visual processing
- **Core Haptics** for synchronized tactile feedback
- **App Intents** and **Shortcuts** for system integrations
- **Apple Foundation Models** for on-device text generation on supported devices
- A deterministic procedural composition system that maps photos to repeatable musical results

The audio engine combines image-derived tonal material with procedural grooves, drum kits, musical roles, and live effect controls.

## Running the project

### Requirements

- Xcode 26 or later
- An iPhone simulator or physical device
- An Apple Developer signing team for device builds

Apple Intelligence support is optional and is only required for features powered by Foundation Models. Camera, haptic, audio, and Apple Intelligence behavior should be validated on a physical device.

### Setup

```bash
git clone https://github.com/Katupilly/Dap.git
cd Dap
open DapNext.xcodeproj
```

In Xcode:

1. Select the `Dap` target.
2. Choose your development team under **Signing & Capabilities**.
3. Select an iPhone simulator or physical device.
4. Build and run the project.

## Project status

Dap is in active development and is being prepared for its App Store release.

Current work focuses on refining the photo-to-music experience, audio behavior, accessibility, sharing, onboarding, and App Store presentation.

## About the project

Dap is an independent project designed and developed by [Pedro Kosciuk](https://pedrokosciuk.vercel.app).

The project explores the intersection of:

- Interaction and product design
- Generative music systems
- Photography and memory
- On-device artificial intelligence
- Specification-driven and agentic development
- Game design principles applied to creative tools

## Feedback

Feedback and bug reports can be submitted through [GitHub Issues](https://github.com/Katupilly/Dap/issues).
