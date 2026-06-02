import SwiftUI
import UniformTypeIdentifiers

/// Drag-and-drop / browse picker for attaching one or more files to a Jira issue, with an
/// optional comment. Same keybindings as the other dialogs: Cmd-Return submits, Escape cancels.
struct UploadFilesDialog: View {
    let issueKey: String
    let onSubmit: ([URL], String, @escaping (Bool) -> Void) -> Void
    let onCancel: () -> Void

    @State private var files: [URL] = []
    @State private var comment: String = ""
    @State private var submitting: Bool = false
    @State private var isDropTargeted: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "paperclip")
                    .foregroundColor(.accentColor)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Upload Files")
                        .font(.title3)
                        .fontWeight(.semibold)
                    Text(issueKey)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }

            dropZone

            HStack {
                Button {
                    browseForFiles()
                } label: {
                    Label("Browse…", systemImage: "folder")
                }
                Spacer()
                if !files.isEmpty {
                    Button("Clear all") { files.removeAll() }
                        .controlSize(.small)
                }
            }

            if !files.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(files.enumerated()), id: \.offset) { index, url in
                            fileRow(url, index: index)
                        }
                    }
                }
                .frame(maxHeight: 140)
                .background(Color(NSColor.textBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color(NSColor.separatorColor), lineWidth: 1)
                )
            }

            Text("Comment (optional)")
                .font(.headline)
            TextField("", text: $comment, axis: .vertical)
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .lineLimit(3...6)

            Spacer(minLength: 0)

            HStack {
                Button("") { submit() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .frame(width: 0, height: 0)
                    .opacity(0)
                    .accessibilityHidden(true)
                    .disabled(submitting || files.isEmpty)

                Spacer()
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button(submitting ? "Uploading…" : "Upload") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(submitting || files.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 520, height: 540)
    }

    private var dropZone: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(
                    isDropTargeted ? Color.accentColor : Color(NSColor.separatorColor),
                    style: StrokeStyle(lineWidth: isDropTargeted ? 2 : 1, dash: [6])
                )
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isDropTargeted ? Color.accentColor.opacity(0.08) : Color.clear)
                )

            VStack(spacing: 6) {
                Image(systemName: "tray.and.arrow.down")
                    .font(.system(size: 28))
                    .foregroundColor(isDropTargeted ? .accentColor : .secondary)
                Text(isDropTargeted ? "Release to add" : "Drop files here or click Browse…")
                    .foregroundColor(isDropTargeted ? .accentColor : .secondary)
                    .font(.callout)
            }
        }
        .frame(height: 100)
        .onDrop(of: [UTType.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
        }
    }

    private func fileRow(_ url: URL, index: Int) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "doc")
                .foregroundColor(.secondary)
            VStack(alignment: .leading, spacing: 0) {
                Text(url.lastPathComponent)
                Text(humanSize(for: url))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button {
                files.remove(at: index)
            } label: {
                Image(systemName: "xmark.circle")
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 6)
    }

    // MARK: - Helpers

    private func browseForFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        if panel.runModal() == .OK {
            appendUnique(panel.urls)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let group = DispatchGroup()
        var dropped: [URL] = []
        for provider in providers {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                    dropped.append(url)
                } else if let url = item as? URL {
                    dropped.append(url)
                }
            }
        }
        group.notify(queue: .main) {
            appendUnique(dropped)
        }
        return !providers.isEmpty
    }

    private func appendUnique(_ urls: [URL]) {
        for url in urls where !files.contains(where: { $0 == url }) {
            files.append(url)
        }
    }

    private func humanSize(for url: URL) -> String {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        let bytes = Int64(values?.fileSize ?? 0)
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private func submit() {
        guard !submitting, !files.isEmpty else { return }
        submitting = true
        onSubmit(files, comment) { success in
            if !success { submitting = false }
        }
    }
}
