import CoreGraphics
import Foundation
import UIKit
import XCTest

@testable import Dap

final class PhotoMusicPipelineTests: XCTestCase {
    func testSameImageKeepsSequenceAndSignatureAcrossNewUUIDs() async throws {
        let data = makeGrid(primary: .systemRed, secondary: .black)
        let first = try await PhotoMusicPipeline.process(imageData: data)
        let second = try await PhotoMusicPipeline.process(imageData: data)

        XCTAssertNotEqual(first.sound.id, second.sound.id)
        XCTAssertEqual(first.sound.sequence, second.sound.sequence)
        XCTAssertEqual(first.sound.visualSignature, second.sound.visualSignature)
        XCTAssertEqual(
            first.sound.sequence.harmony.rootPitchClass,
            second.sound.sequence.harmony.rootPitchClass
        )
        XCTAssertEqual(first.sound.algorithmVersion, PhotoMusicPipeline.currentAlgorithmVersion)
    }

    func testColorAndColorPositionChangeThePhotoSignature() async throws {
        let red = try await PhotoMusicPipeline.process(
            imageData: makeGrid(primary: redColor, secondary: blackColor)
        )
        let blue = try await PhotoMusicPipeline.process(
            imageData: makeGrid(primary: blueColor, secondary: blackColor)
        )
        let swapped = try await PhotoMusicPipeline.process(
            imageData: makeGrid(primary: redColor, secondary: blueColor, swap: true)
        )
        let originalPosition = try await PhotoMusicPipeline.process(
            imageData: makeGrid(primary: redColor, secondary: blueColor)
        )

        XCTAssertEqual(red.sound.sequence.harmony.rootPitchClass, PitchClass.c.rawValue)
        XCTAssertNotEqual(red.sound.sequence.harmony.rootPitchClass, blue.sound.sequence.harmony.rootPitchClass)
        XCTAssertNotEqual(stepPitchClasses(red.sound.sequence), stepPitchClasses(blue.sound.sequence))
        XCTAssertNotEqual(
            stepPitchClasses(originalPosition.sound.sequence),
            stepPitchClasses(swapped.sound.sequence)
        )
    }

    func testSmallRelatedEditKeepsRootAndMostlyKeepsStructure() async throws {
        let original = try await PhotoMusicPipeline.process(
            imageData: makeGrid(primary: redColor, secondary: blueColor)
        )
        let edited = try await PhotoMusicPipeline.process(
            imageData: makeGrid(primary: redColor, secondary: blueColor, smallEdit: true)
        )

        XCTAssertEqual(
            original.sound.sequence.harmony.rootPitchClass,
            edited.sound.sequence.harmony.rootPitchClass
        )
        XCTAssertGreaterThanOrEqual(
            sharedStepCount(original.sound.sequence, edited.sound.sequence),
            max(1, Int(Double(original.sound.sequence.notes.count) * 0.75))
        )
    }

    func testContrastControlsDensityAndNeutralFallbackIsStable() async throws {
        let white = try await PhotoMusicPipeline.process(imageData: makeSolid(whiteColor))
        let black = try await PhotoMusicPipeline.process(imageData: makeSolid(blackColor))
        let blackAgain = try await PhotoMusicPipeline.process(imageData: makeSolid(blackColor))

        XCTAssertLessThan(white.sound.sequence.notes.count, MusicSequence.steps)
        XCTAssertEqual(black.sound.sequence.harmony.rootPitchClass, PitchClass.c.rawValue)
        XCTAssertEqual(black.sound.sequence.notes.count, 4)
        XCTAssertEqual(black.sound.sequence, blackAgain.sound.sequence)
        XCTAssertEqual(Set(black.sound.sequence.notes.map(\.step)).count, 4)
    }

    func testSequenceHasAtMostOneMelodicEventPerStep() async throws {
        let result = try await PhotoMusicPipeline.process(
            imageData: makeGrid(primary: orangeColor, secondary: blueColor)
        )
        let counts = Dictionary(grouping: result.sound.sequence.notes, by: \.step)
            .mapValues(\.count)

        XCTAssertLessThanOrEqual(result.sound.sequence.notes.count, MusicSequence.steps)
        XCTAssertTrue(counts.values.allSatisfy { $0 <= 1 })
    }

    func testJamPreservesMelodyAndDoesNotUseUUIDForVariation() async throws {
        let result = try await PhotoMusicPipeline.process(
            imageData: makeGrid(primary: pinkColor, secondary: blackColor)
        )
        let original = result.sound
        let reimported = PhotoSound(
            id: UUID(),
            name: original.name,
            nameSource: original.nameSource,
            description: original.description,
            createdAt: original.createdAt,
            coverFilename: original.coverFilename,
            sequence: original.sequence,
            algorithmVersion: original.algorithmVersion,
            visualSignature: original.visualSignature
        )
        let builder = JamArrangementBuilder(bpm: 96)
        let originalArrangement = builder.build(
            assignedSounds: [AssignedSound(sound: original, role: .melody)],
            vibePosition: CGPoint(x: 0.5, y: 0.5),
            drumKit: .soft
        )
        let reimportedArrangement = builder.build(
            assignedSounds: [AssignedSound(sound: reimported, role: .melody)],
            vibePosition: CGPoint(x: 0.5, y: 0.5),
            drumKit: .soft
        )

        guard let originalArrangement, let reimportedArrangement else {
            return XCTFail("A playable Melody Photo should build a Jam arrangement")
        }

        let sourceSteps = Set(original.sequence.notes.map(\.step))
        let melodySteps = Set(
            originalArrangement.sequence.notes
                .filter { $0.voiceRole == .melody }
                .map(\.step)
        )
        XCTAssertTrue(melodySteps.isSubset(of: sourceSteps))
        XCTAssertGreaterThanOrEqual(
            melodySteps.count,
            max(1, Int((Double(sourceSteps.count) * 0.82).rounded(.down)))
        )
        XCTAssertEqual(originalArrangement.sequence.harmony.scale, original.sequence.harmony.scale)
        XCTAssertEqual(originalArrangement.sequence.harmony.rootPitchClass, original.sequence.harmony.rootPitchClass)
        XCTAssertEqual(originalArrangement.sequence.harmony.bpm, 96)
        XCTAssertEqual(originalArrangement.percussion, reimportedArrangement.percussion)
        XCTAssertEqual(
            melodySignature(originalArrangement.sequence),
            melodySignature(reimportedArrangement.sequence)
        )
    }

    func testBassAndHarmonyStayInJamHarmony() async throws {
        let sources = try await [
            PhotoMusicPipeline.process(imageData: makeGrid(primary: redColor, secondary: blackColor)).sound,
            PhotoMusicPipeline.process(imageData: makeGrid(primary: blueColor, secondary: blackColor)).sound,
            PhotoMusicPipeline.process(imageData: makeGrid(primary: greenColor, secondary: blackColor)).sound
        ]
        let assigned = [
            AssignedSound(sound: sources[0], role: .bass),
            AssignedSound(sound: sources[1], role: .harmony),
            AssignedSound(sound: sources[2], role: .melody)
        ]
        let arrangement = try XCTUnwrap(
            JamArrangementBuilder(bpm: 96).build(
                assignedSounds: assigned,
                vibePosition: CGPoint(x: 0.5, y: 0.5),
                drumKit: .soft
            )
        )
        let harmonyPitchClasses = Set(
            arrangement.sequence.harmony.scale.degrees.map {
                (arrangement.sequence.harmony.rootPitchClass + $0) % 12
            }
        )

        for note in arrangement.sequence.notes {
            XCTAssertTrue(harmonyPitchClasses.contains(PitchClass(normalizing: note.midiNote).rawValue))
            switch note.voiceRole {
            case .bass:
                XCTAssertTrue((48...72).contains(note.midiNote))
            case .harmony:
                XCTAssertTrue((54...90).contains(note.midiNote))
            default:
                break
            }
        }
    }

    func testLegacyPhotoSoundDecodesWithoutNewMetadata() throws {
        let sequence = MusicSequence(
            harmony: MusicHarmony(rootPitchClass: 0, scale: .minorPentatonic, bpm: 96),
            notes: [MusicNote(step: 0, row: 4, midiNote: 60, velocity: 0.5)],
            soundProfile: SoundProfile(gate: 0.7, octaveRange: 1, waveform: .triangle)
        )
        let sound = PhotoSound(
            id: UUID(),
            name: nil,
            nameSource: nil,
            description: nil,
            createdAt: Date(timeIntervalSince1970: 1),
            coverFilename: "legacy.png",
            sequence: sequence
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(sound)) as? [String: Any]
        )
        object.removeValue(forKey: "algorithmVersion")
        object.removeValue(forKey: "visualSignature")
        let decoded = try JSONDecoder().decode(
            PhotoSound.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        XCTAssertEqual(decoded.sequence, sequence)
        XCTAssertEqual(decoded.algorithmVersion, PhotoSound.legacyAlgorithmVersion)
        XCTAssertNil(decoded.visualSignature)
    }

    /// Persisted v3 records must keep decoding (and keep playing) after we
    /// bump `currentAlgorithmVersion` to 6. The decoder must not coerce v3
    /// into v6 — the on-disk value is authoritative for the existing record.
    func testV3PhotoSoundDecodesAfterAlgorithmBump() throws {
        let sequence = MusicSequence(
            harmony: MusicHarmony(rootPitchClass: 0, scale: .minorPentatonic, bpm: 96),
            notes: [MusicNote(step: 0, row: 4, midiNote: 60, velocity: 0.5)],
            soundProfile: SoundProfile(gate: 0.7, octaveRange: 1, waveform: .triangle)
        )
        let v3 = PhotoSound(
            id: UUID(),
            name: "v3",
            nameSource: nil,
            description: nil,
            createdAt: Date(timeIntervalSince1970: 1),
            coverFilename: "v3.png",
            sequence: sequence,
            algorithmVersion: 3,
            visualSignature: 0xABCD
        )
        let decoded = try JSONDecoder().decode(
            PhotoSound.self,
            from: JSONEncoder().encode(v3)
        )

        XCTAssertEqual(decoded.algorithmVersion, 3)
        XCTAssertEqual(decoded.sequence, sequence)
        XCTAssertEqual(decoded.visualSignature, 0xABCD)
        XCTAssertNotEqual(decoded.algorithmVersion, PhotoMusicPipeline.currentAlgorithmVersion)
    }

    func testSingleCompletionGateConcurrentContention() async {
        for _ in 0..<50 {
            let gate = PhotoMusicPipeline.SingleCompletionGate()
            let winners = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
                for _ in 0..<64 {
                    group.addTask {
                        await Task.yield()
                        return gate.tryFire()
                    }
                }

                var results: [Bool] = []
                for await result in group {
                    results.append(result)
                }
                return results
            }

            XCTAssertEqual(winners.filter { $0 }.count, 1)
        }
    }

    func testTimeoutRaceFastOperationWins() async {
        let result = await PhotoMusicPipeline.runWithTimeout(
            timeout: .milliseconds(50),
            fallback: false
        ) {
            await delayIgnoringCancellation(milliseconds: 20)
            return true
        }

        XCTAssertTrue(result)
    }

    func testTimeoutRaceReturnsFallbackBeforeSlowOperationFinishes() async {
        let clock = ContinuousClock()
        let startedAt = clock.now
        let result = await PhotoMusicPipeline.runWithTimeout(
            timeout: .milliseconds(50),
            fallback: false
        ) {
            await delayIgnoringCancellation(milliseconds: 500)
            return true
        }
        let elapsed = startedAt.duration(to: clock.now)

        XCTAssertFalse(result)
        XCTAssertLessThan(elapsed, .milliseconds(200))
    }

    func testTimeoutRaceExternalCancellationReturnsFallback() async throws {
        let clock = ContinuousClock()
        let task = Task {
            await PhotoMusicPipeline.runWithTimeout(
                timeout: .milliseconds(300),
                fallback: false
            ) {
                await delayIgnoringCancellation(milliseconds: 500)
                return true
            }
        }
        try await Task.sleep(for: .milliseconds(20))
        let startedAt = clock.now
        task.cancel()
        let result = await task.value
        let elapsed = startedAt.duration(to: clock.now)

        XCTAssertFalse(result)
        XCTAssertLessThan(elapsed, .milliseconds(200))
    }

    func testTimeoutRaceDiscardsLateCompletion() async throws {
        let lateCompletions = CompletionCounter()
        let result = await PhotoMusicPipeline.runWithTimeout(
            timeout: .milliseconds(50),
            fallback: 0
        ) {
            await delayIgnoringCancellation(milliseconds: 500)
            await lateCompletions.record()
            return 1
        }

        XCTAssertEqual(result, 0)
        try await Task.sleep(for: .milliseconds(600))
        let completionCount = await lateCompletions.value
        XCTAssertEqual(completionCount, 1)
        XCTAssertEqual(result, 0)
    }

    func testChromaticRootIsDeterministicAcrossReimports() async throws {
        let data = makeGrid(primary: redColor, secondary: blueColor)
        let first = try await PhotoMusicPipeline.process(imageData: data).sound
        let second = try await PhotoMusicPipeline.process(imageData: data).sound
        let third = try await PhotoMusicPipeline.process(imageData: data).sound

        XCTAssertEqual(first.sequence.harmony.rootPitchClass, second.sequence.harmony.rootPitchClass)
        XCTAssertEqual(second.sequence.harmony.rootPitchClass, third.sequence.harmony.rootPitchClass)
    }

    func testPipelineCompletesWhenVisionFindsNoFace() async throws {
        // Synthetic images have no detectable face. The pipeline must finish
        // with a valid root rather than hanging on the face-detection timeout
        // or returning a partial profile.
        let data = makeGrid(primary: greenColor, secondary: blackColor)
        let sound = try await PhotoMusicPipeline.process(imageData: data).sound

        XCTAssertGreaterThanOrEqual(sound.sequence.harmony.rootPitchClass, 0)
        XCTAssertLessThan(sound.sequence.harmony.rootPitchClass, 12)
        XCTAssertEqual(sound.sequence.harmony.rootPitchClass, PitchClass.e.rawValue)
        XCTAssertEqual(sound.algorithmVersion, PhotoMusicPipeline.currentAlgorithmVersion)
    }

    func testV4PhotoSoundDecodesAfterBumpingNewPhotoVersionToSix() throws {
        let sequence = MusicSequence(
            harmony: MusicHarmony(rootPitchClass: 0, scale: .minorPentatonic, bpm: 96),
            notes: [MusicNote(step: 0, row: 4, midiNote: 60, velocity: 0.5)],
            soundProfile: SoundProfile(gate: 0.7, octaveRange: 1, waveform: .triangle)
        )
        let v4 = PhotoSound(
            id: UUID(),
            name: "v4",
            nameSource: nil,
            description: nil,
            createdAt: Date(timeIntervalSince1970: 1),
            coverFilename: "v4.png",
            sequence: sequence,
            algorithmVersion: 4,
            visualSignature: 0xBEEF
        )

        let decoded = try JSONDecoder().decode(PhotoSound.self, from: JSONEncoder().encode(v4))

        XCTAssertEqual(decoded.algorithmVersion, 4)
        XCTAssertEqual(decoded.sequence, sequence)
        XCTAssertNotEqual(decoded.algorithmVersion, PhotoMusicPipeline.currentAlgorithmVersion)
    }

    func testV5PhotoSoundDecodesAfterBumpingNewPhotoVersionToSix() throws {
        let sequence = MusicSequence(
            harmony: MusicHarmony(rootPitchClass: 5, scale: .majorPentatonic, bpm: 96),
            notes: [MusicNote(step: 0, row: 3, midiNote: 65, velocity: 0.5)],
            soundProfile: SoundProfile(gate: 0.7, octaveRange: 1, waveform: .square)
        )
        let v5 = PhotoSound(
            id: UUID(),
            name: "v5",
            nameSource: nil,
            description: nil,
            createdAt: Date(timeIntervalSince1970: 1),
            coverFilename: "v5.png",
            sequence: sequence,
            algorithmVersion: 5,
            visualSignature: 0xCAFE
        )

        let decoded = try JSONDecoder().decode(PhotoSound.self, from: JSONEncoder().encode(v5))

        XCTAssertEqual(decoded.algorithmVersion, 5)
        XCTAssertEqual(decoded.sequence, sequence)
        XCTAssertNotEqual(decoded.algorithmVersion, PhotoMusicPipeline.currentAlgorithmVersion)
    }

    func testProceduralRootsDistributeAcrossMoreThanThreePitchClasses() {
        let roots = Set((0..<64).map { signature in
            PhotoMusicPipeline.proceduralRootPitchClass(from: UInt64(signature) * 0x10001)
        })

        XCTAssertGreaterThan(roots.count, 3)
    }

    func testProceduralRootIsDeterministicAndUsesItsSalt() {
        let signature: UInt64 = 0x1234_5678_9ABC_DEF0
        let salt: UInt64 = 0x726F6F74_73656564
        let expected = Int(PhotoMusicPipeline.splitMix64(signature ^ salt) % 12)

        XCTAssertEqual(
            PhotoMusicPipeline.proceduralRootPitchClass(from: signature),
            PhotoMusicPipeline.proceduralRootPitchClass(from: signature)
        )
        XCTAssertEqual(PhotoMusicPipeline.proceduralRootPitchClass(from: signature), expected)
        XCTAssertNotEqual(
            PhotoMusicPipeline.proceduralRootPitchClass(from: signature),
            Int(signature % 12)
        )
    }

    func testColorPathRemainsActiveWhenPortraitOverrideIsFalse() async throws {
        let red = try await PhotoMusicPipeline.process(
            imageData: makeSolid(redColor),
            overrides: PhotoMusicAnalysisOverrides(portraitDominant: false)
        ).sound
        let green = try await PhotoMusicPipeline.process(
            imageData: makeSolid(greenColor),
            overrides: PhotoMusicAnalysisOverrides(portraitDominant: false)
        ).sound
        let blue = try await PhotoMusicPipeline.process(
            imageData: makeSolid(blueColor),
            overrides: PhotoMusicAnalysisOverrides(portraitDominant: false)
        ).sound

        XCTAssertEqual(red.sequence.harmony.rootPitchClass, PitchClass.c.rawValue)
        XCTAssertEqual(green.sequence.harmony.rootPitchClass, PitchClass.e.rawValue)
        XCTAssertNotEqual(red.sequence.harmony.rootPitchClass, blue.sequence.harmony.rootPitchClass)
    }

    func testProceduralPathIgnoresColorAsASeparateRootSource() async throws {
        let red = try await PhotoMusicPipeline.process(
            imageData: makeSolid(redColor),
            overrides: PhotoMusicAnalysisOverrides(portraitDominant: true)
        ).sound
        let blue = try await PhotoMusicPipeline.process(
            imageData: makeSolid(blueColor),
            overrides: PhotoMusicAnalysisOverrides(portraitDominant: true)
        ).sound
        let redSignature = try XCTUnwrap(red.visualSignature)
        let blueSignature = try XCTUnwrap(blue.visualSignature)

        XCTAssertEqual(
            red.sequence.harmony.rootPitchClass,
            PhotoMusicPipeline.proceduralRootPitchClass(from: redSignature)
        )
        XCTAssertEqual(
            blue.sequence.harmony.rootPitchClass,
            PhotoMusicPipeline.proceduralRootPitchClass(from: blueSignature)
        )
    }

    func testProceduralCoverUsesCanonicalPaletteForPersistedRoot() async throws {
        let input = makeSolid(redColor)
        let processed = try await PhotoMusicPipeline.process(
            imageData: input,
            overrides: PhotoMusicAnalysisOverrides(portraitDominant: true)
        )
        let root = PitchClass(normalizing: processed.sound.sequence.harmony.rootPitchClass)
        let source = try XCTUnwrap(UIImage(data: input)?.cgImage)
        let expectedCGImage = try RetroCoverRenderer.patternHalftone(
            cgImage: source,
            palette: RetroCoverRenderer.tonalPalette(for: root)
        )
        let expectedData = try XCTUnwrap(UIImage(cgImage: expectedCGImage).pngData())

        XCTAssertEqual(
            processed.coverData,
            expectedData
        )
    }

    private func makeSolid(_ color: UIColor) -> Data {
        makeImage { context, size in
            context.setFillColor(color.cgColor)
            context.fill(CGRect(origin: .zero, size: size))
        }
    }

    private func makeGrid(
        primary: UIColor,
        secondary: UIColor,
        swap: Bool = false,
        smallEdit: Bool = false
    ) -> Data {
        makeImage { context, size in
            let columns = 16
            let rows = 8
            let cellWidth = size.width / CGFloat(columns)
            let cellHeight = size.height / CGFloat(rows)
            for row in 0..<rows {
                for column in 0..<columns {
                    let isPrimary = (row + column).isMultiple(of: 2) != swap
                    context.setFillColor((isPrimary ? primary : secondary).cgColor)
                    context.fill(CGRect(
                        x: CGFloat(column) * cellWidth,
                        y: CGFloat(row) * cellHeight,
                        width: cellWidth + 0.5,
                        height: cellHeight + 0.5
                    ))
                }
            }
            if smallEdit {
                context.setFillColor(secondary.cgColor)
                context.fill(CGRect(x: size.width * 0.47, y: size.height * 0.47, width: 2, height: 2))
            }
        }
    }

    private func makeImage(_ draw: (CGContext, CGSize) -> Void) -> Data {
        let size = CGSize(width: 128, height: 64)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.pngData { context in
            draw(context.cgContext, size)
        }
    }

    private func stepPitchClasses(_ sequence: MusicSequence) -> [String] {
        sequence.notes
            .sorted { $0.step < $1.step }
            .map { "\($0.step):\(PitchClass(normalizing: $0.midiNote).rawValue)" }
    }

    private func sharedStepCount(_ lhs: MusicSequence, _ rhs: MusicSequence) -> Int {
        Set(lhs.notes.map(\.step)).intersection(Set(rhs.notes.map(\.step))).count
    }

    private func melodySignature(_ sequence: MusicSequence) -> [String] {
        sequence.notes
            .filter { $0.voiceRole == .melody }
            .sorted { $0.step < $1.step }
            .map { "\($0.step):\($0.midiNote)" }
    }

    private let redColor = UIColor(red: 0.85, green: 0.08, blue: 0.06, alpha: 1)
    private let blueColor = UIColor(red: 0.06, green: 0.16, blue: 0.88, alpha: 1)
    private let greenColor = UIColor(red: 0.08, green: 0.72, blue: 0.20, alpha: 1)
    private let orangeColor = UIColor(red: 0.94, green: 0.36, blue: 0.04, alpha: 1)
    private let pinkColor = UIColor(red: 0.92, green: 0.10, blue: 0.48, alpha: 1)
    private let blackColor = UIColor(red: 0, green: 0, blue: 0, alpha: 1)
    private let whiteColor = UIColor(red: 1, green: 1, blue: 1, alpha: 1)
}

private func delayIgnoringCancellation(milliseconds: Int) async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(milliseconds)) {
            continuation.resume()
        }
    }
}

private actor CompletionCounter {
    private(set) var value = 0

    func record() {
        value += 1
    }
}
