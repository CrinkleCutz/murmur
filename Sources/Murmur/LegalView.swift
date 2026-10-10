import AppKit
import SwiftUI

// MARK: - Legal
//
// Laid out like every other page: small section labels over white cards. Murmur's own license, where its source
// lives and how it treats your data; then every open-source component shipped inside it, and every speech model it
// downloads, each with a one-line plain description and its license as a chip. Clicking one opens its license in a
// sheet — readable, selectable, copyable — instead of the old small boxes that scrolled inside the page's own scroll.
//
// Components ship in the app, so their licenses (and the extra notices some of them carry — WhisperKit's NOTICES,
// FluidAudio's third-party licenses, Sparkle's external licenses) are reproduced in full, as they require. Models are
// downloaded, not shipped; their entries give the credit their licenses ask for (CC BY 4.0's attribution and note of
// changes, the NVIDIA Open Model License's notice, the FunASR license's source and model name) and link the license.
// Every license here was checked against the project's own LICENSE file or the model's own page on 2026-09-26.

struct LegalPage: View {
    @Binding var page: Page
    @State private var shown: LegalEntry?

    static let sourceURL = URL(string: "https://github.com/janisbelozerovs-dev/murmur")!

    var body: some View {
        GlassPanelPage {
            // `ThinScrollView`, not a plain `ScrollView` — see
            // ScratchpadView.swift's own note on why: a bare
            // `.scrollIndicators(.hidden)` doesn't reliably suppress
            // macOS's native scroller by itself.
            ThinScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header

                    SettingsSectionLabel(title: "MURMUR")
                        .padding(.top, 24)
                    SettingsCard {
                        entryRow(.murmur)
                        CardRow(title: "Source code", detail: "Every line of Murmur is public on GitHub.",
                                action: { NSWorkspace.shared.open(Self.sourceURL) }) {
                            RowDestinationLabel(title: "GitHub", external: true)
                        }
                        CardRow(title: "Your privacy",
                                detail: "What stays on this Mac, and the few things that go online.",
                                isLast: true,
                                action: {
                                    // Help reads its remembered tab on appear, so this lands on Privacy.
                                    UserDefaults.standard.set(HelpTab.privacy.rawValue, forKey: "helpTab")
                                    page = .help
                                }) {
                            RowDestinationLabel(title: "Help")
                        }
                    }

                    SettingsSectionLabel(title: "BUILT WITH", trailing: "Click one to read its license")
                        .padding(.top, 24)
                    SettingsCard {
                        ForEach(Array(LegalEntry.components.enumerated()), id: \.element.id) { index, entry in
                            entryRow(entry, isLast: index == LegalEntry.components.count - 1)
                        }
                    }

                    SettingsSectionLabel(title: "SPEECH MODELS", trailing: "Downloaded to this Mac when needed")
                        .padding(.top, 24)
                    SettingsCard {
                        ForEach(Array(LegalEntry.models.enumerated()), id: \.element.id) { index, entry in
                            entryRow(entry, isLast: index == LegalEntry.models.count - 1)
                        }
                    }
                }
            }
        }
        .sheet(item: $shown) { LicenseSheet(entry: $0) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Legal")
                .font(.manrope(22, .medium))
                .tracking(-0.33)
                .foregroundStyle(Palette.warmInk)
            Text("Murmur's own license, the open-source software it's built with and the speech models it uses — "
                 + "each license in full, or the credit it asks for.")
                .font(.manrope(12.5))
                .foregroundStyle(Palette.warmInkFaint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func entryRow(_ entry: LegalEntry, isLast: Bool = false) -> some View {
        CardRow(title: entry.name, detail: entry.purpose, isLast: isLast, action: { shown = entry }) {
            HStack(spacing: 8) {
                LicenseChip(text: entry.license)
                MurmurIconView(icon: .caret)
                    .frame(width: 9, height: 9)
                    .foregroundStyle(Palette.warmInkFaint)
            }
            .fixedSize()
        }
    }
}

/// A license's short name, as a quiet grey chip.
private struct LicenseChip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.manrope(11, .medium))
            .foregroundStyle(Palette.warmInkSoft)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Palette.warmRowBorder, in: Capsule())
            .fixedSize()
    }
}

/// One entry's license, full size: its name and chip, what it is, links to the project and the license, the text
/// itself (monospaced, selectable, scrolling inside the sheet), Copy, and Done (Return or Esc).
private struct LicenseSheet: View {
    let entry: LegalEntry
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(entry.name)
                    .font(.manrope(16, .semibold))
                    .foregroundStyle(Palette.warmInk)
                LicenseChip(text: entry.license)
                Spacer(minLength: 0)
            }
            Text(entry.purpose)
                .font(.manrope(12))
                .foregroundStyle(Palette.warmInkSoft)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
            if !entry.links.isEmpty {
                HStack(spacing: 16) {
                    ForEach(Array(entry.links.enumerated()), id: \.offset) { _, link in
                        Button { NSWorkspace.shared.open(link.url) } label: {
                            RowDestinationLabel(title: link.title, external: true)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 8)
            }
            ThinScrollView {
                Text(entry.text)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Palette.warmInkSoft)
                    .lineSpacing(2)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            }
            .frame(height: 320)
            .background(Palette.homeGradientBottom, in: RoundedRectangle(cornerRadius: Radius.sm))
            .overlay(RoundedRectangle(cornerRadius: Radius.sm).stroke(Palette.warmRowBorder, lineWidth: 1))
            .padding(.top, 16)
            HStack(spacing: 16) {
                Button(copied ? "Copied" : "Copy license") {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(entry.text, forType: .string)
                    copied = true
                }
                .buttonStyle(.plain)
                .font(.manrope(13, .medium))
                .foregroundStyle(Palette.warmInkSoft)
                Spacer()
                Button { dismiss() } label: {
                    Text("Done")
                        .font(.manrope(13, .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .frame(height: 34)
                        .background(Palette.navActivePill, in: RoundedRectangle(cornerRadius: Radius.md))
                }
                .buttonStyle(PressScaleButtonStyle(scale: 0.97))
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 18)
        }
        .padding(22)
        .frame(width: 640)
        .background(Palette.panel)
        .onExitCommand { dismiss() }
    }
}

// MARK: - Entries

struct LegalEntry: Identifiable {
    var id: String { name }
    let name: String
    let purpose: String
    /// The chip: the license's short name.
    let license: String
    /// The license in full, or — for a downloaded model — the credit its license asks for.
    let text: String
    var links: [(title: String, url: URL)] = []

    private static func link(_ title: String, _ url: String) -> (title: String, url: URL) {
        (title, URL(string: url)!)
    }

    private static let ccBy = link("CC BY 4.0", "https://creativecommons.org/licenses/by/4.0/")
    private static let apache = link("Apache 2.0", "https://www.apache.org/licenses/LICENSE-2.0")

    static let murmur = LegalEntry(
        name: "Murmur",
        purpose: "Copyright © 2026 Murmur contributors. Free and open source under the MIT License.",
        license: "MIT",
        text: LegalTexts.murmurLicense,
        links: [link("github.com/janisbelozerovs-dev/murmur", "https://github.com/janisbelozerovs-dev/murmur")])

    static let components: [LegalEntry] = [
        LegalEntry(
            name: "WhisperKit",
            purpose: "Runs Whisper speech models on the Neural Engine.",
            license: "MIT",
            text: LegalTexts.mit(copyright: "Copyright (c) 2024 argmax, inc.")
                + "\n\n" + String(repeating: "=", count: 80) + "\n\n" + LegalTexts.whisperKitNotices,
            links: [link("github.com/argmaxinc/WhisperKit", "https://github.com/argmaxinc/WhisperKit")]),
        LegalEntry(
            name: "whisper.cpp",
            purpose: "Runs Whisper speech models on the graphics chip.",
            license: "MIT",
            text: LegalTexts.mit(copyright: "Copyright (c) 2023-2026 The ggml authors"),
            links: [link("github.com/ggml-org/whisper.cpp", "https://github.com/ggml-org/whisper.cpp")]),
        LegalEntry(
            name: "FluidAudio",
            purpose: Notetaker.isAvailable
                ? "Runs Parakeet and Nemotron, and tells speakers apart in Notetaker."
                : "Runs Parakeet and Nemotron.",
            license: "Apache 2.0",
            text: LegalTexts.apacheLicense
                + "\n\n" + String(repeating: "=", count: 80) + "\nTHIRD-PARTY LICENSES INCLUDED IN FLUIDAUDIO\n"
                + String(repeating: "=", count: 80) + "\n\n" + LegalTexts.fluidAudioNemoTextProcessing
                + "\n\n" + String(repeating: "-", count: 80) + "\nfastcluster\n\n" + LegalTexts.fluidAudioFastcluster
                + "\n\n" + String(repeating: "-", count: 80) + "\nVBx\n\n" + LegalTexts.fluidAudioVBx,
            links: [link("github.com/FluidInference/FluidAudio", "https://github.com/FluidInference/FluidAudio")]),
        LegalEntry(
            name: "sherpa-onnx",
            purpose: "Runs the experimental engine that uses only the processor.",
            license: "Apache 2.0",
            text: "Copyright (c) 2023 Xiaomi Corporation\n\n" + LegalTexts.apacheLicense,
            links: [link("github.com/k2-fsa/sherpa-onnx", "https://github.com/k2-fsa/sherpa-onnx")]),
        LegalEntry(
            name: "ONNX Runtime",
            purpose: "What sherpa-onnx runs on.",
            license: "MIT",
            text: LegalTexts.mit(copyright: "Copyright (c) Microsoft Corporation"),
            links: [link("github.com/microsoft/onnxruntime", "https://github.com/microsoft/onnxruntime")]),
        LegalEntry(
            name: "Harper",
            purpose: "Checks grammar and spelling in English dictation.",
            license: "Apache 2.0",
            text: LegalTexts.harperLicense,
            links: [link("github.com/Automattic/harper", "https://github.com/Automattic/harper")]),
        LegalEntry(
            name: "MLX",
            purpose: "Runs the translation models on the graphics chip.",
            license: "MIT",
            text: "MLX\n\n" + LegalTexts.mit(copyright: "Copyright © 2023 Apple Inc.")
                + "\n\n" + String(repeating: "-", count: 80) + "\nMLX Swift\n\n"
                + LegalTexts.mit(copyright: "Copyright (c) 2023 ml-explore")
                + "\n\n" + String(repeating: "-", count: 80) + "\nMLX Swift LM\n\n"
                + LegalTexts.mit(copyright: "Copyright (c) 2024 ml-explore"),
            links: [link("github.com/ml-explore/mlx-swift", "https://github.com/ml-explore/mlx-swift")]),
        LegalEntry(
            name: "swift-transformers",
            purpose: "Reads the translation models' vocabularies.",
            license: "Apache 2.0 · MIT",
            text: "swift-transformers, swift-jinja and swift-huggingface by Hugging Face, and Swift Crypto, Swift "
                + "Collections, Swift Numerics and SwiftASN1 by Apple Inc. and the Swift project authors, are "
                + "licensed under the Apache License, Version 2.0.\n\n" + LegalTexts.apacheLicense
                + "\n\n" + String(repeating: "-", count: 80) + "\nyyjson\n\n"
                + LegalTexts.mit(copyright: "Copyright (c) 2020 YaoYuan <ibireme@gmail.com>")
                + "\n\n" + String(repeating: "-", count: 80) + "\nEventSource\n\n"
                + LegalTexts.mit(copyright: "Copyright 2025 Mattt (https://mat.tt)"),
            links: [link("github.com/huggingface/swift-transformers", "https://github.com/huggingface/swift-transformers")]),
        LegalEntry(
            name: "Sparkle",
            purpose: "Finds and installs updates in official builds.",
            license: "MIT",
            text: LegalTexts.sparkleLicense,
            links: [link("sparkle-project.org", "https://sparkle-project.org")]),
        LegalEntry(
            name: "Manrope",
            purpose: "The typeface throughout Murmur.",
            license: "SIL OFL 1.1",
            text: LegalTexts.manropeOFL,
            links: [link("github.com/sharanda/manrope", "https://github.com/sharanda/manrope")]),
        LegalEntry(
            name: "Phosphor Icons",
            purpose: "Every icon in Murmur.",
            license: "MIT",
            text: LegalTexts.mit(copyright: "Copyright (c) 2023 Phosphor Icons"),
            links: [link("phosphoricons.com", "https://phosphoricons.com")]),
    ]

    static let models: [LegalEntry] = [
        LegalEntry(
            name: "Gemma 4",
            purpose: "By Google. Translate into, if you download it.",
            license: "Apache 2.0",
            text: """
                Gemma 4 E4B (instruction-tuned) by Google, licensed under the Apache License, Version 2.0.

                Murmur uses the 4-bit MLX version converted by the MLX Community: \
                https://huggingface.co/mlx-community/gemma-4-e4b-it-4bit
                """,
            links: [link("Google's model page", "https://huggingface.co/google/gemma-4-E4B-it"), apache]),
        LegalEntry(
            name: "EuroLLM",
            purpose: "By the EuroLLM project. Translate into for Latvian, if you download it.",
            license: "Apache 2.0",
            text: """
                EuroLLM-9B-Instruct by the EuroLLM project (Unbabel, Instituto Superior Técnico, the University of \
                Edinburgh and partners), licensed under the Apache License, Version 2.0.

                Murmur uses the 4-bit MLX version converted by stelterlab: \
                https://huggingface.co/stelterlab/EuroLLM-9B-Instruct-MLX-4bit
                """,
            links: [link("Model page", "https://huggingface.co/utter-project/EuroLLM-9B-Instruct"), apache]),
        LegalEntry(
            name: "Whisper",
            purpose: "By OpenAI. The Whisper and whisper.cpp engines.",
            license: "Apache 2.0 · MIT",
            text: """
                Whisper speech recognition models by OpenAI.

                Base, Small and Large v3 are licensed under the Apache License, Version 2.0; Large v3 Turbo under \
                the MIT License.

                The Whisper engine uses Core ML versions converted by Argmax, Inc. (MIT License): \
                https://huggingface.co/argmaxinc/whisperkit-coreml

                The whisper.cpp engine uses ggml versions converted by the whisper.cpp authors (MIT License): \
                https://huggingface.co/ggerganov/whisper.cpp
                """,
            links: [link("huggingface.co/openai", "https://huggingface.co/openai"), apache]),
        LegalEntry(
            name: "Distil-Whisper",
            purpose: "By Hugging Face. Distil Large v3 in the Whisper engine.",
            license: "MIT",
            text: """
                Distil-Whisper distil-large-v3 by Hugging Face, a distilled version of OpenAI's Whisper, licensed \
                under the MIT License.

                Murmur uses the Core ML version converted by Argmax, Inc. (MIT License).
                """,
            links: [link("huggingface.co/distil-whisper", "https://huggingface.co/distil-whisper/distil-large-v3")]),
        LegalEntry(
            name: "Whisper Large v3 for Latvian",
            purpose: "By AiLab IMCS, University of Latvia. The Latvian model in whisper.cpp.",
            license: "Apache 2.0",
            text: """
                whisper-large-v3-lv-late-cv19, OpenAI's Whisper Large v3 fine-tuned for Latvian by the Artificial \
                Intelligence Laboratory (AiLab) of the Institute of Mathematics and Computer Science, University of \
                Latvia. Licensed under the Apache License, Version 2.0.

                Murmur uses its ggml (8-bit) version from the same page.
                """,
            links: [link("Model page", "https://huggingface.co/AiLab-IMCS-UL/whisper-large-v3-lv-late-cv19"), apache]),
        LegalEntry(
            name: "Parakeet",
            purpose: Notetaker.isAvailable
                ? "By NVIDIA. The Parakeet engine, Notetaker, and vocabulary boosting."
                : "By NVIDIA. The Parakeet engine and vocabulary boosting.",
            license: "CC BY 4.0",
            text: """
                Parakeet TDT 0.6B v2 and v3, and Parakeet CTC 110M and 0.6B, by NVIDIA. Licensed under the Creative \
                Commons Attribution 4.0 International License (CC BY 4.0): \
                https://creativecommons.org/licenses/by/4.0/

                Changes: converted to Core ML by Fluid Inference — https://huggingface.co/FluidInference
                """,
            links: [link("NVIDIA's model page", "https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3"), ccBy]),
        LegalEntry(
            name: "Nemotron Speech Streaming",
            purpose: "By NVIDIA. The Nemotron model in the Parakeet engine.",
            license: "NVIDIA Open Model License",
            text: """
                Licensed by NVIDIA Corporation under the NVIDIA Open Model License.

                nemotron-speech-streaming-en-0.6b by NVIDIA: \
                https://www.nvidia.com/en-us/agreements/enterprise-software/nvidia-open-model-license/

                Changes: converted to Core ML by Fluid Inference — \
                https://huggingface.co/FluidInference/nemotron-speech-streaming-en-0.6b-coreml
                """,
            links: [link("License", "https://www.nvidia.com/en-us/agreements/enterprise-software/nvidia-open-model-license/")]),
        LegalEntry(
            name: "Canary 180M Flash",
            purpose: "By NVIDIA. A model in the sherpa-onnx engine.",
            license: "CC BY 4.0",
            text: """
                canary-180m-flash by NVIDIA. Licensed under the Creative Commons Attribution 4.0 International \
                License (CC BY 4.0): https://creativecommons.org/licenses/by/4.0/

                Changes: converted to ONNX (8-bit) by the sherpa-onnx project — https://github.com/k2-fsa/sherpa-onnx
                """,
            links: [link("Model page", "https://huggingface.co/nvidia/canary-180m-flash"), ccBy]),
        LegalEntry(
            name: "SenseVoice Small",
            purpose: "By FunAudioLLM, Alibaba Group. A model in the sherpa-onnx engine.",
            license: "FunASR Model License",
            text: """
                SenseVoiceSmall, by FunAudioLLM (Tongyi Lab, Alibaba Group) — https://huggingface.co/FunAudioLLM/SenseVoiceSmall

                Used under the FunASR Model Open Source License Agreement, version 1.1, Copyright (C) 2023-2028 \
                Alibaba Group: https://github.com/modelscope/FunASR/blob/main/MODEL_LICENSE

                Changes: converted to ONNX (8-bit) by the sherpa-onnx project — https://github.com/k2-fsa/sherpa-onnx
                """,
            links: [link("License", "https://github.com/modelscope/FunASR/blob/main/MODEL_LICENSE")]),
        LegalEntry(
            name: "Fun-ASR-Nano",
            purpose: "By FunAudioLLM, Alibaba Group. A model in the sherpa-onnx engine.",
            license: "Apache 2.0",
            text: """
                Fun-ASR-Nano by FunAudioLLM (Tongyi Lab, Alibaba Group), licensed under the Apache License, \
                Version 2.0.

                Changes: converted to ONNX (8-bit) by the sherpa-onnx project — https://github.com/k2-fsa/sherpa-onnx
                """,
            links: [link("Model page", "https://huggingface.co/FunAudioLLM/Fun-ASR-Nano-2512"), apache]),
        LegalEntry(
            name: "Qwen3-ASR",
            purpose: "By the Qwen team, Alibaba Cloud. A model in the sherpa-onnx engine.",
            license: "Apache 2.0",
            text: """
                Qwen3-ASR-0.6B by the Qwen team, Alibaba Cloud, licensed under the Apache License, Version 2.0.

                Changes: converted to ONNX (8-bit) by the sherpa-onnx project — https://github.com/k2-fsa/sherpa-onnx
                """,
            links: [link("Model page", "https://huggingface.co/Qwen/Qwen3-ASR-0.6B"), apache]),
        LegalEntry(
            name: "Silero VAD",
            purpose: "By Silero. Tells your speech from silence.",
            license: "MIT",
            text: """
                Silero VAD by the Silero team, licensed under the MIT License — https://github.com/snakers4/silero-vad

                Changes: converted to Core ML by Fluid Inference — https://huggingface.co/FluidInference/silero-vad-coreml
                """,
            links: [link("github.com/snakers4/silero-vad", "https://github.com/snakers4/silero-vad")]),
        LegalEntry(
            name: "Speaker recognition",
            purpose: "By pyannote, WeSpeaker and BUT Speech@FIT. Tells speakers apart in Notetaker.",
            license: "CC BY 4.0",
            text: """
                Notetaker's speaker models are derived from pyannote's speaker-diarization-community-1 \
                (https://huggingface.co/pyannote/speaker-diarization-community-1), with WeSpeaker speaker \
                embeddings and PLDA parameters from Brno University of Technology / BUT Speech@FIT. Licensed under \
                the Creative Commons Attribution 4.0 International License (CC BY 4.0): \
                https://creativecommons.org/licenses/by/4.0/

                Changes: modified Core ML conversions by Fluid Inference — the PyTorch components converted to Core \
                ML with fixed input shapes and mixed-precision storage, and the FBank frontend separated from the \
                embedding backend. https://huggingface.co/FluidInference/speaker-diarization-coreml
                """,
            links: [link("Model page", "https://huggingface.co/FluidInference/speaker-diarization-coreml"), ccBy]),
    ].filter { $0.name != "Speaker recognition" || Notetaker.isAvailable }
}
