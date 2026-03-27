import SwiftUI
import AudioToolbox
import CoreAudioKit

// MARK: - Main View

public struct IMPSYMainView: View {
    @ObservedObject var viewModel: IMPSYViewModel

    public init(viewModel: IMPSYViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                headerView
                modelSection
                parametersSection
                stateSection
                mappingsSection
            }
            .padding(16)
        }
        .background(platformBackground)
        .frame(minWidth: 380, minHeight: 520)
    }

    // MARK: - Sections

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
    }

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionLabel("Model")
            ModelStatusView(viewModel: viewModel)
        }
    }

    private var parametersSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionLabel("Parameters")
            ParameterControlsView(viewModel: viewModel)
        }
    }

    private var stateSection: some View {
        HStack {
            HStack(spacing: 6) {
                Circle()
                    .fill(viewModel.callResponseState == "RESPONSE" ? Color.green : Color.orange)
                    .frame(width: 10, height: 10)
                Text(viewModel.callResponseState)
                    .font(.system(.subheadline, design: .monospaced, weight: .semibold))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color.primary.opacity(0.08)))

            Spacer()

            Button("Reset LSTM") { viewModel.resetLSTM() }
                .buttonStyle(.bordered)
                .disabled(!viewModel.modelStatus.isReady)
        }
    }

    private var mappingsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionLabel("MIDI Mappings")
            MappingEditorView(viewModel: viewModel)
                .frame(minHeight: 200)
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(.caption, design: .rounded, weight: .semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .tracking(0.5)
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

public final class IMPSYViewController: AUViewController {

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
}

#elseif os(macOS)
import AppKit

public final class IMPSYViewController: AUViewController {

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
}
#endif
