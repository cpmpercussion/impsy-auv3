import SwiftUI
import AudioToolbox
import CoreAudioKit

// MARK: - Main View
//
// Three-screen layout: Dashboard / Settings / MIDI Mapping. A segmented picker
// at the top switches screens. Each screen scrolls independently so the
// minimum AUv3 surface (≈ 320×240 on iPhone) stays usable.

public struct IMPSYMainView: View {
    @ObservedObject var viewModel: IMPSYViewModel
    @State private var screen: Screen = .dashboard

    enum Screen: String, CaseIterable, Identifiable {
        case dashboard = "Dashboard"
        case settings  = "Settings"
        case mapping   = "Mapping"
        var id: String { rawValue }
    }

    init(viewModel: IMPSYViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(spacing: 10) {
            headerView

            Picker("Screen", selection: $screen) {
                ForEach(Screen.allCases) { s in
                    Text(s.rawValue).tag(s)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)

            ScrollView {
                screenContent
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
            }
        }
        .padding(.top, 12)
        .background(platformBackground)
        #if os(macOS)
        // Give the macOS window a sensible minimum; iOS adapts to its host.
        .frame(minWidth: 380, minHeight: 520)
        #endif
    }

    @ViewBuilder
    private var screenContent: some View {
        switch screen {
        case .dashboard:
            DashboardView(viewModel: viewModel)
        case .settings:
            SettingsView(viewModel: viewModel)
        case .mapping:
            // MappingEditorView contains its own padded background, so it
            // slots straight into the scroll view.
            MappingEditorView(viewModel: viewModel)
        }
    }

    private var headerView: some View {
        HStack {
            Text("IMPSY")
                .font(.system(.title2, design: .rounded, weight: .bold))
            Text("AUv3")
                .font(.system(.subheadline, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.leading, 2)
            Spacer()
        }
        .padding(.horizontal, 16)
    }

    private var platformBackground: Color {
        #if os(iOS)
        Color(UIColor.systemBackground)
        #elseif os(macOS)
        Color(NSColor.windowBackgroundColor)
        #else
        Color.white
        #endif
    }
}

// MARK: - AUv3 View Controller (wraps SwiftUI view)

#if os(iOS)
import UIKit

public final class IMPSYViewController: AUViewController, AUAudioUnitFactory {

    private let viewModel = IMPSYViewModel()

    public var audioUnit: IMPSYAudioUnit? {
        didSet {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.viewModel.audioUnit = self.audioUnit
            }
        }
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        let mainView = IMPSYMainView(viewModel: viewModel)
        let hc = UIHostingController(rootView: mainView)
        addChild(hc)
        view.addSubview(hc.view)
        hc.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hc.view.topAnchor.constraint(equalTo: view.topAnchor),
            hc.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hc.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hc.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        hc.didMove(toParent: self)
        preferredContentSize = CGSize(width: 400, height: 560)
    }

    /// `AUAudioUnitFactory` entry point. The AUv3 host (AUM, GarageBand, …)
    /// instantiates this view controller as the extension's principal class,
    /// then calls this to create the audio unit.
    public func createAudioUnit(
        with componentDescription: AudioComponentDescription
    ) throws -> AUAudioUnit {
        let au = try IMPSYAudioUnit(componentDescription: componentDescription, options: [])
        audioUnit = au
        return au
    }
}

#elseif os(macOS)
import AppKit

public final class IMPSYViewController: AUViewController, AUAudioUnitFactory {

    private let viewModel = IMPSYViewModel()

    public var audioUnit: IMPSYAudioUnit? {
        didSet {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.viewModel.audioUnit = self.audioUnit
            }
        }
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        let mainView = IMPSYMainView(viewModel: viewModel)
        let hc = NSHostingController(rootView: mainView)
        addChild(hc)
        view.addSubview(hc.view)
        hc.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hc.view.topAnchor.constraint(equalTo: view.topAnchor),
            hc.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hc.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hc.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        preferredContentSize = CGSize(width: 400, height: 560)
    }

    /// `AUAudioUnitFactory` entry point. The AUv3 host instantiates this view
    /// controller as the extension's principal class, then calls this to
    /// create the audio unit.
    public func createAudioUnit(
        with componentDescription: AudioComponentDescription
    ) throws -> AUAudioUnit {
        let au = try IMPSYAudioUnit(componentDescription: componentDescription, options: [])
        audioUnit = au
        return au
    }
}
#endif
