import SwiftUI

#if os(iOS)
import UIKit
import UniformTypeIdentifiers
#elseif os(macOS)
import AppKit
#endif

// MARK: - Logging Controls
//
// Folder picker + enable/disable toggle for session logging. Logs are written
// in the IMPSY Python `.log` format (../impsy/impsy/interaction.py) so they
// can feed straight into the IMPSY training pipeline.

struct LoggingControlsView: View {
    @ObservedObject var viewModel: IMPSYViewModel
    @State private var showFolderPicker = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Toggle(isOn: Binding(
                    get: { viewModel.loggingEnabled },
                    set: { viewModel.setLoggingEnabled($0) }
                )) {
                    Text("Record Session Logs")
                }
                .toggleStyle(.switch)
                .accessibilityIdentifier("logging.toggle")
                Spacer()
            }

            HStack(spacing: 8) {
                folderPickerButton
                if let path = viewModel.logFolderPath {
                    Text(path)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .accessibilityIdentifier("logging.folderPath")
                } else {
                    Text("No folder selected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("logging.folderPath")
                }
            }
        }
    }

    @ViewBuilder
    private var folderPickerButton: some View {
        #if os(iOS)
        Button("Choose Folder…") { showFolderPicker = true }
            .sheet(isPresented: $showFolderPicker) {
                LogFolderPicker { url in
                    showFolderPicker = false
                    viewModel.setLogFolder(url: url)
                }
            }
        #elseif os(macOS)
        Button("Choose Folder…") {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles       = false
            panel.allowsMultipleSelection = false
            panel.message = "Choose a folder for IMPSY .log files"
            panel.prompt  = "Choose"
            if panel.runModal() == .OK, let url = panel.url {
                viewModel.setLogFolder(url: url)
            }
        }
        #endif
    }
}

#if os(iOS)
private struct LogFolderPicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        init(onPick: @escaping (URL) -> Void) { self.onPick = onPick }
        func documentPicker(_ controller: UIDocumentPickerViewController,
                            didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            onPick(url)
        }
    }
}
#endif
