import SwiftUI
import AudioToolbox
import CoreAudioKit

// MARK: - Main View

public struct IMPSYMainView: View {
    @ObservedObject var viewModel: IMPSYViewModel

    init(viewModel: IMPSYViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                headerView
                modelSection
                parametersSection
                activitySection
                mappingsSection
            }
            .padding(16)
        }
        .background(platformBackground)
        #if os(macOS)
        // Give the macOS window a sensible minimum; iOS adapts to its host.
        .frame(minWidth: 380, minHeight: 520)
        #endif
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

    private var activitySection: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionLabel("Activity")
            VStack(spacing: 10) {
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

                    // Flashes once per prediction, like a MIDI interface LED
                    HStack(spacing: 4) {
                        PredictionLED(trigger: viewModel.generatedEventCount)
                        Text("ACT")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.leading, 6)

                    Spacer()

                    Button("Reset LSTM") { viewModel.resetLSTM() }
                        .buttonStyle(.bordered)
                        .disabled(!viewModel.modelStatus.isReady)
                }

                HStack(spacing: 0) {
                    metric("Events", "\(viewModel.generatedEventCount)")
                    Divider().frame(height: 30)
                    metric("Last Δt", String(format: "%.3f s", viewModel.lastEventDt))
                    Divider().frame(height: 30)
                    metric("Last MIDI", viewModel.lastEventSummary)
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
        }
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.callout, design: .monospaced, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

// MARK: - Prediction Activity LED

/// A small indicator that flashes once each time a prediction is made,
/// emulating the activity LED on a MIDI interface.
private struct PredictionLED: View {
    /// Increments once per prediction; every change triggers one flash.
    let trigger: Int
    @State private var lit = false

    var body: some View {
        Circle()
            .fill(lit ? Color.green : Color.green.opacity(0.18))
            .frame(width: 9, height: 9)
            .overlay(Circle().strokeBorder(Color.green.opacity(0.4), lineWidth: 0.5))
            .shadow(color: lit ? Color.green : .clear, radius: lit ? 3.5 : 0)
            .onChange(of: trigger) { _, _ in flash() }
            .accessibilityHidden(true)
    }

    private func flash() {
        // Two transactions: an instant "on", then a quick fade. Doing both in
        // one synchronous block would net to no change and never render lit.
        lit = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
            withAnimation(.easeOut(duration: 0.2)) { lit = false }
        }
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
