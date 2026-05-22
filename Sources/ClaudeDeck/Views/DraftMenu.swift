import SwiftUI

/// Context-menu submenu offering AI-drafted replies that open a review modal.
struct DraftReplyMenu: View {
    let session: Session
    @EnvironmentObject var summarizer: Summarizer
    @Binding var showCustomSheet: Bool

    var body: some View {
        if summarizer.hasApiKey {
            Menu {
                Button {
                    summarizer.draftReply(for: session, intent: .approve)
                } label: {
                    Label("Approve / proceed", systemImage: "checkmark.circle")
                }
                Button {
                    summarizer.draftReply(for: session, intent: .clarify)
                } label: {
                    Label("Ask a clarifying question", systemImage: "questionmark.bubble")
                }
                Button {
                    summarizer.draftReply(for: session, intent: .redirect)
                } label: {
                    Label("Push back / change direction", systemImage: "arrow.uturn.left")
                }
                Divider()
                Button {
                    showCustomSheet = true
                } label: {
                    Label("Custom note…", systemImage: "text.cursor")
                }
            } label: {
                Label("Draft reply", systemImage: "wand.and.stars")
            }
        } else {
            Button("Set API key to draft replies", action: {})
                .disabled(true)
        }
    }
}

/// Sheet for typing a custom intent ("say yes but use plan B"). Sends to LLM →
/// result lands in DraftReviewSheet for the user to inspect/copy.
struct CustomDraftSheet: View {
    let session: Session
    @Binding var isPresented: Bool
    @EnvironmentObject var summarizer: Summarizer
    @State private var note: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(LinearGradient(colors: [.orange, .pink],
                                                    startPoint: .topLeading, endPoint: .bottomTrailing))
                Text("Custom note")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                Spacer()
                Button {
                    isPresented = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
            if let title = session.title {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text("Your intent")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            TextEditor(text: $note)
                .focused($focused)
                .font(.system(size: 12.5))
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(minHeight: 80, maxHeight: 140)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(0.05))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                )

            Text("Examples: \"say yes but use plan B\", \"ask why option C wasn't considered\", \"approve everything except the migration\"")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button {
                    let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    summarizer.draftReply(for: session, intent: .custom(trimmed))
                    isPresented = false
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "sparkles")
                        Text("Draft")
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(18)
        .frame(width: 440)
        .onAppear { focused = true }
    }
}

/// Big review modal — shows the LLM-drafted reply, lets you edit it,
/// regenerate with the same intent, then explicitly copy to clipboard.
struct DraftReviewSheet: View {
    @EnvironmentObject var summarizer: Summarizer
    let draft: Summarizer.PendingDraft
    @State private var editedText: String
    @State private var copied = false
    @FocusState private var editorFocused: Bool

    init(draft: Summarizer.PendingDraft) {
        self.draft = draft
        _editedText = State(initialValue: draft.text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(LinearGradient(colors: [.orange, .pink],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 28, height: 28)
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("Drafted reply")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                    HStack(spacing: 6) {
                        intentBadge
                        Text("·")
                            .foregroundStyle(.tertiary)
                        Text(draft.session.title ?? "Untitled session")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                Spacer()
                Button { summarizer.dismissDraft() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }

            // What the agent asked (collapsible context)
            if let context = draft.session.summarizerContext {
                DisclosureGroup {
                    Text(context)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 6)
                } label: {
                    Text("What the agent asked")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }

            // Editable draft
            VStack(alignment: .leading, spacing: 6) {
                Text("Reply (edit before copying)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                TextEditor(text: $editedText)
                    .focused($editorFocused)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .frame(minHeight: 110, maxHeight: 240)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.primary.opacity(0.05))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.orange.opacity(0.25), lineWidth: 1)
                    )
            }

            // Footer actions
            HStack(spacing: 10) {
                Button {
                    summarizer.regenerateCurrentDraft()
                } label: {
                    Label("Regenerate", systemImage: "arrow.clockwise")
                }
                .disabled(summarizer.isDrafting(draft.session))

                Spacer()

                Button("Discard") { summarizer.dismissDraft() }
                    .keyboardShortcut(.cancelAction)

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(
                        editedText.trimmingCharacters(in: .whitespacesAndNewlines),
                        forType: .string
                    )
                    copied = true
                    Task {
                        try? await Task.sleep(nanoseconds: 700_000_000)
                        await MainActor.run { summarizer.dismissDraft() }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: copied ? "checkmark.circle.fill" : "doc.on.clipboard.fill")
                        Text(copied ? "Copied" : "Copy to clipboard")
                            .fontWeight(.semibold)
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(editedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear { editorFocused = true }
    }

    private var intentBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: intentSymbol)
                .font(.system(size: 9, weight: .semibold))
            Text(summarizer.shortIntent(draft.intent).capitalized)
                .font(.system(size: 10.5, weight: .semibold))
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(Capsule().fill(Color.orange.opacity(0.18)))
        .foregroundStyle(Color.orange)
    }

    private var intentSymbol: String {
        switch draft.intent {
        case .approve: return "checkmark.circle"
        case .clarify: return "questionmark.bubble"
        case .redirect: return "arrow.uturn.left"
        case .custom: return "text.cursor"
        }
    }
}

/// A subtle inline indicator we can drop into the header showing that a draft
/// is currently being generated.
struct DraftingSpinner: View {
    @EnvironmentObject var summarizer: Summarizer
    var body: some View {
        if !summarizer.inflightDrafts.isEmpty {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini).tint(.orange)
                Text("Drafting…")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.orange)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.orange.opacity(0.12)))
        }
    }
}
