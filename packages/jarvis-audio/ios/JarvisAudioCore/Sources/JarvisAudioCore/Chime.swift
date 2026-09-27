import Foundation

/// The page's earphone cue (web/src/lib/mic.ts `chime`), as a WAV file: two short notes, falling for muted
/// and rising for listening again. Played natively, since the page can't make a sound in the background.
public enum Chime {
    public static let notes: (high: Double, low: Double) = (880, 587)
    static let gap = 0.1, attack = 0.01, decay = 0.08, length = 0.09, peak = 0.15, floor = 0.0001

    /// The notes' frequencies, in order.
    public static func frequencies(muted: Bool) -> [Double] {
        muted ? [notes.high, notes.low] : [notes.low, notes.high]
    }

    /// Samples in -1...1: each note fades in over 10 ms and out by 80 ms, like the page's exponential ramps.
    public static func samples(muted: Bool, rate: Double = 24_000) -> [Float] {
        let total = Int((gap + length) * rate)
        var out = [Float](repeating: 0, count: total)
        for (i, hz) in frequencies(muted: muted).enumerated() {
            let start = Int(Double(i) * gap * rate)
            for n in 0..<Int(length * rate) where start + n < total {
                let t = Double(n) / rate
                let level: Double
                if t < attack { level = floor * pow(peak / floor, t / attack) }
                else if t < decay { level = peak * pow(floor / peak, (t - attack) / (decay - attack)) }
                else { level = 0 }
                out[start + n] += Float(level * sin(2 * .pi * hz * t))
            }
        }
        return out
    }

    /// A mono 16-bit PCM WAV of `samples`.
    public static func wav(muted: Bool, rate: Int = 24_000) -> Data {
        let pcm = samples(muted: muted, rate: Double(rate)).map { Int16(max(-1, min(1, $0)) * Float(Int16.max)) }
        var d = Data()
        func put(_ s: String) { d.append(contentsOf: Array(s.utf8)) }
        func put32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func put16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        let bytes = UInt32(pcm.count * 2)
        put("RIFF"); put32(36 + bytes); put("WAVE")
        put("fmt "); put32(16); put16(1); put16(1)  // PCM, mono
        put32(UInt32(rate)); put32(UInt32(rate * 2)); put16(2); put16(16)
        put("data"); put32(bytes)
        for s in pcm { put16(UInt16(bitPattern: s)) }
        return d
    }
}
