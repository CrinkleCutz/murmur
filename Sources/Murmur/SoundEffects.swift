import AppKit

/// Murmur's few sounds — a dictation starting and stopping, and the "can't do that" sound — played only while Settings
/// → Dictation → "Play sounds" is on. Every sound the app makes goes through here, so that one switch covers them all.
enum SoundEffect {
    static func play(_ name: String) {
        guard Settings.playSounds else { return }
        NSSound(named: NSSound.Name(name))?.play()
    }
}
