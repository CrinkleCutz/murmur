import Foundation

/// Whether Notetaker can be reached in this build — one switch, read by every
/// place it shows up (sidebar, Settings, Help, Insights, Ask, onboarding,
/// permissions) and every place it would run in the background (the global
/// shortcut, meeting detection, the speaker-model download).
///
/// Off for the first release (2026-10-08): the pipeline works piece by piece
/// but was never run on a real call, and an audit found real gaps — your own
/// side comes out as one unordered block, other voices can merge into one
/// speaker, the summary only reads the first ~7 minutes, and "stop when the
/// call ends" only fires when the call app quits (see
/// `project_murmur_notetaker_audit` in memory; `Murmur --notetaker-check`
/// reproduces the first two). Nothing is deleted: `NotetakerController`,
/// `MeetingTranscriber`, `MeetingAudioCapture`, `LivePreviewTranscriber`,
/// `MeetingNoteStore` and the page itself all stay compiled and working, and
/// notes already saved on disk are left untouched. Flipping this to `true`
/// brings the whole feature back exactly as it was.
enum Notetaker {
    static let isAvailable = false
}
