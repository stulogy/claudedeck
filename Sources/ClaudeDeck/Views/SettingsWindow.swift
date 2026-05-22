import SwiftUI

struct SettingsWindow: View {
    @EnvironmentObject var summarizer: Summarizer
    @State private var apiKeyDraft: String = ""
    @State private var apiKeyTouched = false
    @State private var savedAt: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(LinearGradient(colors: [.accentColor, .purple],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 30, height: 30)
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                }
                Text("Settings")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                Spacer()
            }
            .padding(.horizontal, 22)
            .padding(.top, 20)
            .padding(.bottom, 16)

            Divider().opacity(0.35)

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    sectionCard {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 8) {
                                Image(systemName: "sparkles")
                                    .foregroundStyle(LinearGradient(
                                        colors: [.orange, .pink],
                                        startPoint: .topLeading, endPoint: .bottomTrailing))
                                Text("AI summaries")
                                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                                Spacer()
                                Toggle("", isOn: $summarizer.enabled)
                                    .labelsHidden()
                                    .toggleStyle(.switch)
                                    .disabled(!summarizer.hasApiKey)
                            }

                            Text("Generate a one-line description of what each waiting session is asking you. Uses your own Anthropic API key — calls only run for waiting sessions, and only when enabled.")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)

                            VStack(alignment: .leading, spacing: 6) {
                                Text("Anthropic API key")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                HStack(spacing: 8) {
                                    SecureField("sk-ant-…", text: $apiKeyDraft)
                                        .textFieldStyle(.roundedBorder)
                                        .onChange(of: apiKeyDraft) { _, _ in apiKeyTouched = true }
                                    Button("Save") {
                                        summarizer.apiKey = apiKeyDraft
                                        savedAt = Date()
                                        apiKeyTouched = false
                                    }
                                    .disabled(!apiKeyTouched || apiKeyDraft.isEmpty)
                                    Button("Clear", role: .destructive) {
                                        apiKeyDraft = ""
                                        summarizer.apiKey = nil
                                        summarizer.enabled = false
                                        savedAt = Date()
                                    }
                                    .disabled(!summarizer.hasApiKey)
                                }
                                HStack(spacing: 6) {
                                    if summarizer.hasApiKey {
                                        Image(systemName: "checkmark.seal.fill")
                                            .foregroundStyle(.green)
                                            .font(.system(size: 11))
                                        Text("Key stored in macOS Keychain")
                                            .font(.system(size: 11))
                                            .foregroundStyle(.secondary)
                                    } else {
                                        Image(systemName: "key.slash")
                                            .foregroundStyle(.tertiary)
                                            .font(.system(size: 11))
                                        Text("No key on file")
                                            .font(.system(size: 11))
                                            .foregroundStyle(.tertiary)
                                    }
                                    if let s = savedAt {
                                        Text("· saved \(RelativeTime.short(from: s))")
                                            .font(.system(size: 11))
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                            }

                            VStack(alignment: .leading, spacing: 6) {
                                Text("Model")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                Picker("", selection: $summarizer.model) {
                                    Text("Claude Haiku 4.5 (recommended, fastest, cheapest)")
                                        .tag("claude-haiku-4-5-20251001")
                                    Text("Claude Sonnet 4.6")
                                        .tag("claude-sonnet-4-6")
                                    Text("Claude Opus 4.7")
                                        .tag("claude-opus-4-7")
                                }
                                .labelsHidden()
                                .pickerStyle(.menu)
                            }

                            Text("Privacy: only the last assistant message and tool-call name are sent. Your prompts, file contents, and tool outputs are not.")
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                                .padding(.top, 4)
                        }
                    }

                    sectionCard {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 8) {
                                Image(systemName: "stethoscope")
                                    .foregroundStyle(.tint)
                                Text("Diagnostics")
                                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                                Spacer()
                                Button {
                                    summarizer.clearCache()
                                } label: {
                                    Label("Clear cache", systemImage: "trash")
                                }
                                Button {
                                    summarizer.sendTestRequest()
                                } label: {
                                    Label("Send test request", systemImage: "paperplane.fill")
                                }
                                .disabled(!summarizer.hasApiKey)
                            }

                            statusRow(label: "Enabled", value: summarizer.enabled ? "Yes" : "No",
                                      tint: summarizer.enabled ? .green : .secondary)
                            statusRow(label: "Successes", value: "\(summarizer.successCount)")
                            statusRow(label: "Failures", value: "\(summarizer.failureCount)",
                                      tint: summarizer.failureCount > 0 ? .orange : .secondary)
                            statusRow(label: "In-flight", value: "\(summarizer.inflight.count)")
                            if let s = summarizer.lastSuccessAt {
                                statusRow(label: "Last success", value: RelativeTime.short(from: s))
                            }
                            if let err = summarizer.lastError {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Last error")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                    Text(err)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(.red)
                                        .textSelection(.enabled)
                                        .padding(8)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                                            .fill(Color.red.opacity(0.08)))
                                }
                            }
                            if let test = summarizer.lastTestResult {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Last test result")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                    Text("✨ " + test)
                                        .font(.system(size: 12, weight: .semibold))
                                        .padding(8)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                                            .fill(Color.orange.opacity(0.10)))
                                }
                            }
                        }
                    }
                }
                .padding(22)
            }
        }
        .frame(width: 540, height: 680)
        .background(BackgroundCanvasSettings())
        .onAppear {
            apiKeyDraft = summarizer.apiKey ?? ""
            apiKeyTouched = false
        }
    }

    @ViewBuilder
    private func statusRow(label: String, value: String, tint: Color = .secondary) -> some View {
        HStack {
            Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(tint)
                .monospacedDigit()
        }
    }

    @ViewBuilder
    private func sectionCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.regularMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.07), lineWidth: 1)
            )
    }
}

private struct BackgroundCanvasSettings: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(nsColor: .windowBackgroundColor),
                    Color(nsColor: .underPageBackgroundColor)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            GeometryReader { proxy in
                Circle()
                    .fill(Color.accentColor.opacity(0.16))
                    .frame(width: proxy.size.width * 0.7)
                    .blur(radius: 110)
                    .offset(x: -proxy.size.width * 0.3, y: -proxy.size.height * 0.3)
            }
            .allowsHitTesting(false)
        }
        .ignoresSafeArea()
    }
}
