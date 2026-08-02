<p align="center">
  <img src="docs/readme/app-icon.png" width="112" alt="Dap app icon">
</p>

<h1 align="center">Dap</h1>

<p align="center">
  Turn photos into playable music.
</p>

<p align="center">
  <em>A musical toy for people who do not need to know music theory to start creating.</em>
</p>

About

Dap is an iPhone app that transforms photos into musical material.

Capture or import an image and Dap analyzes its colors, contrast, and visual relationships to generate notes, rhythm, and a playable sequence. Each photo becomes more than something to look at: it becomes an instrument connected to a memory.

The project started from a simple question:

What if creating music could begin with something everyone already knows how to do — taking a photo?

Dap uses photography as a universal gesture to reduce the cognitive barrier of music theory. Instead of asking people to understand scales, harmony, or sequencing before they can create, the app translates visual information into a musical system and gives immediate feedback through sound, motion, and haptics.

How it works

Capture or import a photoStart with an image from a moment, place, person, or texture.

Translate color into musicDap maps visual relationships to notes using a system inspired by the chromatic circle and the circle of fifths.

Generate a sequenceThe app creates a deterministic 16-step musical pattern based on the photo.

Play and remixListen to the photo individually or combine multiple images inside a Jam.

Core features

Capture photos directly from the app

Import images from the photo library

Generate musical sequences from image color and tone

Play each photo as an individual instrument

Combine multiple photos in a Jam

Automatically assign musical roles such as bass, harmony, and melody

Explore different moods through the Vibe control

Add drum kits, reverb, delay, and rhythmic modulation

Export and share generated photo covers

Use Siri and Shortcuts through App Intents

Generate photo names and descriptions with Apple Foundation Models on compatible Apple Intelligence devices

Design principles

Photos before theory

The interface begins with a familiar action instead of a musical abstraction. Users create through images first and learn the musical behavior through play.

Play before configuration

Dap is designed as a musical toy, not a traditional production tool. The first interaction should produce a meaningful result without requiring setup.

Immediate positive feedback

Sound, animation, and haptics work together to make each action feel responsive and intentional.

Memories as instruments

A photo is not treated only as media or documentation. Inside Dap, it becomes something active: a sound that can be replayed, combined, and transformed.

Technical highlights

Dap is built natively for iPhone using:

SwiftUI for the interface and interaction system

AVAudioEngine for synthesis, sequencing, looping, and real-time audio effects

Core Image and custom image analysis for visual processing

Core Haptics for synchronized tactile feedback

App Intents and Shortcuts for system integrations

Apple Foundation Models for on-device text generation on supported devices

A deterministic procedural composition system for mapping photos to repeatable musical results

The audio engine renders tonal material from image-derived sequences and combines it with procedural grooves, drum kits, musical roles, and live effect controls.

Screenshots

<p align="center">
  <img src="docs/readme/gallery.png" width="240" alt="Dap gallery">
  <img src="docs/readme/photo.png" width="240" alt="Generated photo instrument">
  <img src="docs/readme/jam.png" width="240" alt="Dap Jam">
</p>

Add the final App Store screenshots to docs/readme/ using the filenames above.

Requirements

iPhone running iOS 17 or later

Xcode 26 or later

An Apple Developer signing team for device builds

Apple Intelligence support is optional and only required for Foundation Models features

Running locally

git clone https://github.com/Katupilly/Dap.git
cd Dap
open DapNext.xcodeproj

Then:

Select the Dap target.

Choose your development team under Signing & Capabilities.

Select an iPhone simulator or physical device.

Build and run the project.

Some camera, haptic, audio, and Apple Intelligence behaviors are best tested on a physical device.

Project status

Dap is in active development and is being prepared for its App Store release.

The current work focuses on refining the core photo-to-music experience, audio behavior, accessibility, sharing, and onboarding.

About the project

Dap is an independent project designed and developed by Pedro Kosciuk.

It explores the intersection of:

Interaction and product design

Generative music systems

Photography and memory

On-device artificial intelligence

Agentic coding and specification-driven development

Game design principles applied to creative tools

Portfolio · GitHub

Feedback

Feedback and bug reports are welcome through GitHub Issues.

<p align="center">
  Designed and built as a solo project.
</p>
