import Foundation
import Observation

@MainActor
@Observable
final class JamPlaybackController {
    var pendingArrangement: JamArrangement?
    var hasPendingArrangementChanges = false
    var hasPreparedArrangement = false
    var loopIterationAtPending: Int?
    var isDrumKitChangePending = false
    var isPreparedDrumKitChangePending = false
    var isDrumKitPendingIndicatorPulsing = false
    var drumKitConfirmationPulseTrigger = 0
    var appliedArrangementVersion = 0

    private var previousSnapshotStep: Int?

    func beginPendingArrangement(_ arrangement: JamArrangement, loopIteration: Int?) {
        pendingArrangement = arrangement
        loopIterationAtPending = loopIteration
        hasPendingArrangementChanges = true
        hasPreparedArrangement = false
        isPreparedDrumKitChangePending = false
    }

    func beginDrumKitPendingFeedback(reduceMotion: Bool) {
        isPreparedDrumKitChangePending = false
        isDrumKitChangePending = true
        if !reduceMotion {
            isDrumKitPendingIndicatorPulsing = true
        }
    }

    func markLoopUpdatePrepared() {
        if hasPendingArrangementChanges {
            hasPreparedArrangement = true
        }
        if isDrumKitChangePending {
            isPreparedDrumKitChangePending = true
        }
    }

    func promotePendingArrangementIfNeeded(
        from snapshot: MusicPlayer.JamTransportSnapshot
    ) -> JamArrangement? {
        let step = snapshot.currentStep
        let didWrap = previousSnapshotStep.map { previousStep in
            snapshot.loopIteration > (loopIterationAtPending ?? Int.min)
                || (step <= 1 && previousStep >= (MusicSequence.steps - 1))
        } ?? false
        previousSnapshotStep = step

        guard hasPendingArrangementChanges,
              hasPreparedArrangement,
              let pendingArrangement,
              didWrap else {
            return nil
        }

        hasPendingArrangementChanges = false
        hasPreparedArrangement = false
        self.pendingArrangement = nil
        loopIterationAtPending = nil
        appliedArrangementVersion &+= 1
        finishDrumKitPendingFeedbackIfNeeded()
        return pendingArrangement
    }

    func clearPendingState() {
        pendingArrangement = nil
        hasPendingArrangementChanges = false
        hasPreparedArrangement = false
        loopIterationAtPending = nil
        previousSnapshotStep = nil
    }

    func clearDrumKitPendingFeedback() {
        isDrumKitChangePending = false
        isPreparedDrumKitChangePending = false
        isDrumKitPendingIndicatorPulsing = false
    }

    private func finishDrumKitPendingFeedbackIfNeeded() {
        guard isDrumKitChangePending, isPreparedDrumKitChangePending else { return }
        clearDrumKitPendingFeedback()
        drumKitConfirmationPulseTrigger += 1
    }
}
