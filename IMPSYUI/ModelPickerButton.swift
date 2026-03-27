import SwiftUI

#if os(iOS)
import UIKit
import UniformTypeIdentifiers

// MARK: - iOS Document Picker

struct ModelPickerButton: View {
    let onPick: (URL) -> Void
    @State private var showPicker = false

    var body: some View {
        Button("Load Model…") { showPicker = true }
            .sheet(isPresented: $showPicker) {
                DocumentPicker(onPick: { url in
                    showPicker = false
                    onPick(url)
                })
            }
    }
}

private struct DocumentPicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let types: [UTType] = [UTType(filenameExtension: "tflite") ?? .data]
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types)
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

#elseif os(macOS)
import AppKit

// MARK: - macOS Open Panel

struct ModelPickerButton: View {
    let onPick: (URL) -> Void

    var body: some View {
        Button("Load Model…") {
            let panel = NSOpenPanel()
            panel.allowedContentTypes  = []
            panel.allowsOtherFileTypes = true
            panel.message              = "Choose an IMPSY TFLite model file"
            panel.prompt               = "Load"
            if panel.runModal() == .OK, let url = panel.url {
                onPick(url)
            }
        }
    }
}

#endif
