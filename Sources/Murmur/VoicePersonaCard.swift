import SwiftUI

/// The voice-profile persona as one card, shared by Insights' "Your voice"
/// tab and the Voice Profile page — they used to draw the same persona two
/// different ways.
///
/// Home's hero anatomy (uppercase label left, quiet readout right, 33pt
/// headline, chips, waveform) on a white card: orange is an accent in Murmur,
/// never a card fill — here the label, the progress line and the waveform
/// bars.
struct VoicePersonaCard: View {
    @ObservedObject var app: AppDelegate
    /// Shown as a small refresh button beside the readout when set — the
    /// Voice Profile page offers "regenerate now"; Insights doesn't.
    var onRefresh: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                Text("VOICE PROFILE")
                    .font(.manrope(10, .bold))
                    .kerning(0.9)
                    .foregroundStyle(Palette.sunsetDeep)
                Spacer()
                if let profile = app.voiceProfile {
                    // Lifetime words, same count the refresh itself uses —
                    // history's total is capped and could sit below the
                    // profile's own baseline forever.
                    let done = max(app.usageStats.lifetimeWords - profile.wordCountAtGeneration, 0)
                    let progress = min(Double(done) / Double(VoiceProfileStore.refreshThreshold), 1)
                    HStack(spacing: 10) {
                        Text("Next update in \(max(VoiceProfileStore.refreshThreshold - done, 0)) words")
                            .font(.manrope(11.5, .medium))
                            .foregroundStyle(Palette.warmInkSoft)
                        Capsule().fill(Palette.warmRowBorder)
                            .frame(width: 90, height: InsightsBar.height)
                            .overlay(alignment: .leading) {
                                Capsule().fill(Palette.sunset)
                                    .frame(width: 90 * progress, height: InsightsBar.height)
                            }
                    }
                }
                if let onRefresh, app.voiceProfile != nil {
                    IconButton(icon: .refresh, size: 24, iconSize: 12, tint: Palette.warmInk,
                               hoverFill: Palette.hoverWash, help: "Refresh profile now",
                               action: onRefresh)
                }
            }
            HStack(alignment: .center, spacing: 36) {
                VStack(alignment: .leading, spacing: 0) {
                    if let profile = app.voiceProfile {
                        Text(profile.title)
                            .font(.manrope(33, .medium))
                            .tracking(-0.66)
                            .foregroundStyle(Palette.warmInk)
                            .fixedSize(horizontal: false, vertical: true)
                        if !profile.summary.isEmpty {
                            Text(profile.summary)
                                .font(.manrope(15))
                                .foregroundStyle(Palette.warmInkSoft)
                                .lineSpacing(3)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: 520, alignment: .leading)
                                .padding(.top, 8)
                        }
                        if let traits = profile.traits, !traits.isEmpty {
                            HStack(spacing: 8) {
                                ForEach(traits, id: \.self) { trait in
                                    Text(trait)
                                        .font(.manrope(12, .medium))
                                        .foregroundStyle(Palette.warmInk)
                                        .padding(.horizontal, 12)
                                        .frame(height: 28)
                                        .background(Palette.warmRowBorder, in: Capsule())
                                }
                            }
                            .padding(.top, 18)
                        }
                    } else {
                        Text("Keep dictating — Murmur builds this from your own transcripts "
                             + "once you've dictated at least \(VoiceProfileStore.minimumWords) words.")
                            .font(.manrope(15))
                            .foregroundStyle(Palette.warmInkSoft)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                HeroCaptureWaveform(color: Palette.sunset, minOpacity: 0.25)
            }
            .padding(.top, 22)
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 28)
        // White: orange is an accent, never a card fill. No shadow on the
        // glass panel.
        .background(Palette.panel, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}
