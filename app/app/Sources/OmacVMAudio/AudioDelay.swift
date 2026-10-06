import Foundation

/// How late the Mac plays a VM's sound after the VM's sound card took it
/// (av-sync, 3.0.1).
///
/// Players in the VM (Chromium, Firefox, mpv) hold the picture back by the
/// sound delay PipeWire reports. That covers the VM's own buffers only. After
/// the card's DMA position come QEMU's buffers and the Mac's output device,
/// and nothing told the VM about them: the sound came late against the
/// picture (about 150 ms with wired sound, about 320 ms with AirPods).
/// The app now tells the VM this delay (AudioLatencyWatch in the app,
/// omacvm-audio-latency in the VM: PipeWire's latency offset on the card's
/// output port), at the start and whenever the Mac's output changes.
public enum AudioDelay {
    /// QEMU's part in ms, from the guest's DMA position to macOS's mixer: the
    /// HDA codec's buffer (8 KiB, kept half full: 21 ms at 48 kHz), QEMU's
    /// ring (out.buffer-count=8 x 512 frames at 44.1 kHz: 93 ms, kept full)
    /// and SDL's AudioQueue (about 35-46 ms). Measured on the Mac mini with a
    /// flash-and-beep clip in Chromium (app/runtime/Tests/av-sync): the sound
    /// reached macOS's mixer this much after the picture reached the screen.
    public static let qemuMs = 150

    /// What CoreAudio says about the Mac's output device, in frames.
    public struct Device: Equatable, Sendable {
        public var latency: UInt32
        public var safetyOffset: UInt32
        public var streamLatency: UInt32
        public var bufferFrames: UInt32
        public var sampleRate: Double

        public init(latency: UInt32, safetyOffset: UInt32, streamLatency: UInt32,
                    bufferFrames: UInt32, sampleRate: Double) {
            self.latency = latency
            self.safetyOffset = safetyOffset
            self.streamLatency = streamLatency
            self.bufferFrames = bufferFrames
            self.sampleRate = sampleRate
        }

        /// The device's delay in ms (what a Mac app adds to its own A/V
        /// sync): nil when CoreAudio gave no usable rate or a value that
        /// cannot be right (over 1 s).
        public var ms: Double? {
            guard sampleRate >= 8000, sampleRate <= 768_000 else { return nil }
            let frames = Double(latency) + Double(safetyOffset) + Double(streamLatency) + Double(bufferFrames)
            let ms = frames / sampleRate * 1000
            return ms <= 1000 ? ms : nil
        }
    }

    /// The delay the VM is told, in whole ms: QEMU's part, the device's
    /// (none when unknown) and the user's correction (audioDelayExtraMs),
    /// kept within 0 ... 1000 ms.
    public static func total(deviceMs: Double?, extraMs: Int = 0) -> Int {
        let ms = Double(qemuMs) + (deviceMs ?? 0) + Double(extraMs)
        return Int(min(max(ms, 0), 1000).rounded())
    }
}
