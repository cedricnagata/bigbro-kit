import Foundation
import AVFoundation

/// Which output a `.playAndRecord` session should use.
///
/// The question only exists because `.playAndRecord` is pessimistic about output: left alone
/// it drops to the receiver — the earpiece — where a spoken answer is barely audible with the
/// phone on a table. Forcing the speaker fixes that, and is wrong the moment anything is
/// plugged in or paired.
enum BigBroAudioRoute {

    /// Outputs that are already where the user wants the sound.
    ///
    /// Overriding to the speaker while any of these is connected sends the answer out of the
    /// phone instead of the headphones — and on a headset, plays it into the room the headset
    /// microphone is listening to.
    private static let external: Set<AVAudioSession.Port> = [
        .bluetoothA2DP, .bluetoothHFP, .bluetoothLE,
        .headphones, .headsetMic,
        .usbAudio, .carAudio, .airPlay, .lineOut, .HDMI,
    ]

    static var isExternal: Bool {
        AVAudioSession.sharedInstance().currentRoute.outputs
            .contains { external.contains($0.portType) }
    }

    /// Forces the speaker when playing out of the device itself, and gets out of the way
    /// when it isn't.
    ///
    /// `.defaultToSpeaker` alone is not enough: it sets only the *default*, which is given up
    /// whenever the route is re-evaluated — which `.playAndRecord` does on activation and on
    /// every device connect. The override has to be re-asserted, which is why this is called
    /// again from the route-change notification rather than once at setup.
    @MainActor
    static func preferLoudestBuiltIn() {
        let session = AVAudioSession.sharedInstance()
        // `.none` rather than skipping: an override set while the phone was on its own
        // outlives the AirPods connecting, and would keep the answer coming out of the phone.
        try? session.overrideOutputAudioPort(isExternal ? .none : .speaker)
    }
}
