import AppKit

/// Interface sounds from the Kobra sound patch (kobra.systems/components/sound). The web component
/// synthesizes them with Web Audio at play time; this renders the same patch definitions natively
/// (oscillator, pitch sweep, envelope, layer delay) into a short PCM buffer and plays it.
@MainActor
enum Sounds {
    enum Cue: String { case notification, swoosh, copy, success }

    private struct Layer {
        enum Wave { case sine, triangle }
        var wave: Wave
        var start: Double
        var end: Double? = nil
        var attack = 0.0, decay: Double, sustain = 0.0, release = 0.0
        var gain: Double
        var delay = 0.0
    }

    private static let patch: [Cue: [Layer]] = [
        .notification: [
            Layer(wave: .triangle, start: 523, attack: 0.008, decay: 0.3, sustain: 0.03, release: 0.12, gain: 0.14),
            Layer(wave: .triangle, start: 784, attack: 0.008, decay: 0.25, sustain: 0.02, release: 0.1, gain: 0.12, delay: 0.12),
        ],
        .swoosh: [Layer(wave: .sine, start: 300, end: 2000, attack: 0.008, decay: 0.12, release: 0.04, gain: 0.12)],
        .copy: [
            Layer(wave: .sine, start: 1200, decay: 0.015, release: 0.006, gain: 0.16),
            Layer(wave: .sine, start: 1400, decay: 0.015, release: 0.006, gain: 0.14, delay: 0.04),
        ],
        .success: [
            Layer(wave: .triangle, start: 784, attack: 0.004, decay: 0.16, gain: 0.22),
            Layer(wave: .triangle, start: 1175, attack: 0.004, decay: 0.22, gain: 0.18, delay: 0.075),
        ],
    ]
    /// Random detune in cents per cue, as in the Kobra component, so repeats don't sound canned.
    private static let jitter: [Cue: Double] = [.notification: 3, .swoosh: 14, .copy: 6, .success: 5]
    private static let volume = 0.5
    private static let sampleRate = 44_100.0
    private static var playing: [NSSound] = []

    static func play(_ cue: Cue) {
        guard MailStore.shared.settings.playSounds,
              ProcessInfo.processInfo.environment["INKWELL_SNAPSHOT"] == nil,
              let layers = patch[cue] else { return }
        let cents = (Double.random(in: -1...1)) * (jitter[cue] ?? 0)
        let velocity = 0.9 + Double.random(in: 0...0.1)
        guard let sound = NSSound(data: wav(render(layers, detune: cents, gain: velocity * volume))) else { return }
        playing.removeAll { !$0.isPlaying }
        playing.append(sound)
        sound.play()
    }

    private static func render(_ layers: [Layer], detune: Double, gain: Double) -> [Float] {
        let length = layers.map { $0.delay + $0.attack + $0.decay + $0.release }.max() ?? 0
        var out = [Float](repeating: 0, count: Int((length + 0.01) * sampleRate))
        let ratio = pow(2, detune / 1200)
        for l in layers {
            let offset = Int(l.delay * sampleRate)
            let sweep = max(l.attack + l.decay, 0.001)
            let floorLevel = max(l.sustain, 0.0001)
            let n = Int((l.attack + l.decay + l.release) * sampleRate)
            var phase = 0.0
            for i in 0..<n where offset + i < out.count {
                let t = Double(i) / sampleRate
                // Web Audio-style ramps: linear attack, exponential decay to sustain, linear release.
                let env: Double
                if t < l.attack { env = t / l.attack }
                else if t < l.attack + l.decay { env = pow(floorLevel, (t - l.attack) / l.decay) }
                else { env = l.release > 0 ? floorLevel * (1 - (t - l.attack - l.decay) / l.release) : 0 }
                let f = (l.end.map { l.start * pow($0 / l.start, min(t / sweep, 1)) } ?? l.start) * ratio
                phase += f / sampleRate
                phase -= phase.rounded(.down)
                let s = l.wave == .sine ? sin(2 * .pi * phase) : 1 - 4 * abs(phase - 0.5)
                out[offset + i] += Float(s * env * l.gain * gain)
            }
        }
        return out
    }

    private static func wav(_ samples: [Float]) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        let bytes = UInt32(samples.count * 2)
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + bytes); d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(UInt32(sampleRate)); u32(UInt32(sampleRate) * 2); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(bytes)
        for s in samples { u16(UInt16(bitPattern: Int16(max(-1, min(1, s)) * Float(Int16.max)))) }
        return d
    }
}
