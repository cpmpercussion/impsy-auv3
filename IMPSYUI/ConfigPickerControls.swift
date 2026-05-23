import SwiftUI

#if os(iOS)
import UIKit
import UniformTypeIdentifiers
#elseif os(macOS)
import AppKit
import UniformTypeIdentifiers
#endif

// MARK: - ConfigPickerControls
//
// Import / Export buttons for IMPSY TOML config files. Lives on the Settings
// screen. iOS uses `UIDocumentPickerViewController` (open for import, export
// for save). macOS uses `NSOpenPanel` / `NSSavePanel`. See #3.

struct ConfigPickerControls: View {
    @ObservedObject var viewModel: IMPSYViewModel

    @State private var showImporter = false
    @State private var showExporter = false
    @State private var exportURL: URL?
    @State private var status: ConfigStatus = .idle

    enum ConfigStatus: Equatable {
        case idle
        case success(String)
        case error(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button("Import TOML…") { presentImporter() }
                    .buttonStyle(.bordered)
                Button("Export TOML…") { presentExporter() }
                    .buttonStyle(.bordered)
                Spacer()
            }
            statusLine
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
        #if os(iOS)
        .sheet(isPresented: $showImporter) {
            ConfigImporter(onPick: handleImport)
        }
        .sheet(isPresented: $showExporter) {
            if let url = exportURL {
                ConfigExporter(fileURL: url, onComplete: handleExportComplete)
            }
        }
        #endif
    }

    @ViewBuilder
    private var statusLine: some View {
        switch status {
        case .idle:
            EmptyView()
        case .success(let msg):
            Text(msg).font(.caption).foregroundStyle(.green)
        case .error(let msg):
            Text(msg).font(.caption).foregroundStyle(.red)
                .lineLimit(3)
        }
    }

    // MARK: - Import

    private func presentImporter() {
        #if os(iOS)
        showImporter = true
        #elseif os(macOS)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "toml") ?? .data]
        panel.allowsOtherFileTypes = true
        panel.message = "Choose an IMPSY TOML config file"
        panel.prompt = "Import"
        if panel.runModal() == .OK, let url = panel.url {
            handleImport(url: url)
        }
        #endif
    }

    private func handleImport(url: URL) {
        do {
            try viewModel.loadConfig(url: url)
            status = .success("Imported \(url.lastPathComponent)")
        } catch {
            status = .error("Import failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Export

    private func presentExporter() {
        #if os(iOS)
        // On iOS, the export picker needs a real file to copy. Write the
        // current state to the app's tmp dir first; the system picker then
        // lets the user choose where to put it.
        do {
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent(defaultExportFilename())
            try viewModel.exportConfig(to: tmp)
            exportURL = tmp
            showExporter = true
        } catch {
            status = .error("Export failed: \(error.localizedDescription)")
        }
        #elseif os(macOS)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "toml") ?? .data]
        panel.allowsOtherFileTypes = true
        panel.message = "Save IMPSY TOML config"
        panel.prompt = "Save"
        panel.nameFieldStringValue = defaultExportFilename()
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try viewModel.exportConfig(to: url)
                status = .success("Exported \(url.lastPathComponent)")
            } catch {
                status = .error("Export failed: \(error.localizedDescription)")
            }
        }
        #endif
    }

    private func handleExportComplete(result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            status = .success("Exported \(url.lastPathComponent)")
        case .failure(let error):
            status = .error("Export failed: \(error.localizedDescription)")
        }
    }

    private func defaultExportFilename() -> String {
        "impsy-config.toml"
    }
}

// MARK: - iOS Pickers

#if os(iOS)

private struct ConfigImporter: UIViewControllerRepresentable {
    let onPick: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let types: [UTType] = [UTType(filenameExtension: "toml") ?? .data]
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

private struct ConfigExporter: UIViewControllerRepresentable {
    let fileURL: URL
    let onComplete: (Result<URL, Error>) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: [fileURL], asCopy: true)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onComplete: onComplete) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onComplete: (Result<URL, Error>) -> Void
        init(onComplete: @escaping (Result<URL, Error>) -> Void) { self.onComplete = onComplete }
        func documentPicker(_ controller: UIDocumentPickerViewController,
                            didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            onComplete(.success(url))
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {}
    }
}

#endif
