import SwiftUI

// MARK: - Dashboard View
//
// At-a-glance read-only display of what the plugin is doing right now: model
// status, CALL/RESPONSE state, MIDI activity LEDs (aggregate + per-dimension),
// and the most recent generated event.

struct DashboardView: View {
    @ObservedObject var viewModel: IMPSYViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            modelStatusCard
            stateCard
            fadersCard
            perDimensionCard
            lastEventCard
            Spacer(minLength: 0)
        }
    }

    // MARK: - Cards

    private var modelStatusCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionLabel("Model")
            VStack(alignment: .leading, spacing: 2) {
                Text(viewModel.modelName)
                    .font(.system(.subheadline, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityIdentifier("dashboard.modelName")
                Text(viewModel.modelStatus.displayString)
                    .font(.caption)
                    .foregroundStyle(statusColor)
                    .accessibilityIdentifier("dashboard.modelStatus")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
        }
    }

    private var stateCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionLabel("State")
            HStack {
                HStack(spacing: 6) {
                    Circle()
                        .fill(viewModel.callResponseState == "RESPONSE" ? Color.green : Color.orange)
                        .frame(width: 10, height: 10)
                    Text(viewModel.callResponseState)
                        .font(.system(.subheadline, design: .monospaced, weight: .semibold))
                        .accessibilityIdentifier("dashboard.callResponseState")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color.primary.opacity(0.08)))

                HStack(spacing: 4) {
                    ActivityLED(trigger: viewModel.inputEventCount, color: .red)
                    ActivityLED(trigger: viewModel.generatedEventCount, color: .green)
                    Text("ACT")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, 6)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("MIDI activity")

                Spacer()

                // Reset LSTM lives on the dashboard, not Settings, so it's
                // one tap away during performance.
                Button("Reset LSTM") { viewModel.resetLSTM() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!viewModel.modelStatus.isReady)
                    .accessibilityHint("Clears IMPSY's memory and restarts its musical state")
                    .accessibilityIdentifier("dashboard.resetLSTM")
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
        }
    }

    private var perDimensionCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionLabel("Per-Dimension Activity")
            VStack(spacing: 6) {
                if viewModel.inputDimensionCounts.isEmpty {
                    Text("Load a model to see dimension activity")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 8)
                } else {
                    dimensionRow(label: "IN",
                                 counts: viewModel.inputDimensionCounts,
                                 color: .red)
                    dimensionRow(label: "OUT",
                                 counts: viewModel.outputDimensionCounts,
                                 color: .green)
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
        }
    }

    private func dimensionRow(label: String, counts: [Int], color: Color) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(.caption2, design: .monospaced, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 28, alignment: .leading)
            // Wrap so this works on narrow AUv3 widths even for higher
            // dimensions: 12+ LEDs would overflow a single HStack on iPhone.
            FlowLayout(spacing: 6) {
                ForEach(counts.indices, id: \.self) { i in
                    DimensionLED(index: i + 1, trigger: counts[i], color: color)
                }
            }
        }
    }

    private var fadersCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionLabel("Direct Input")
            VStack(spacing: 6) {
                if viewModel.outputValues.isEmpty {
                    Text("Load a model to drive dimensions directly")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 8)
                } else {
                    ForEach(viewModel.outputValues.indices, id: \.self) { i in
                        DimensionFader(
                            dimension: i + 1,
                            modelValue: viewModel.outputValues[i],
                            inputValue: viewModel.inputValues.indices.contains(i)
                                ? viewModel.inputValues[i] : 0,
                            inputTrigger: viewModel.inputDimensionCounts.indices.contains(i)
                                ? viewModel.inputDimensionCounts[i] : 0,
                            outputTrigger: viewModel.outputDimensionCounts.indices.contains(i)
                                ? viewModel.outputDimensionCounts[i] : 0,
                            onDrag: { value in
                                viewModel.injectInput(dimensionIndex: i, value: value)
                            }
                        )
                    }
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
        }
    }

    private var lastEventCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionLabel("Last Output")
            HStack(spacing: 12) {
                metric("Events", "\(viewModel.generatedEventCount)")
                metric("Δt", String(format: "%.3f s", viewModel.lastEventDt))
                metric("MIDI", viewModel.lastEventSummary)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
        }
    }

    // MARK: - Helpers

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

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(.caption, design: .rounded, weight: .semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .tracking(0.5)
    }

    private var statusColor: Color {
        switch viewModel.modelStatus {
        case .ready:   return .green
        case .error:   return .red
        case .loading: return .yellow
        case .noModel: return .secondary
        }
    }
}

// MARK: - Activity LED

/// Reused from the old single-view layout. Flashes once each time `trigger`
/// changes — the value itself is irrelevant, only its monotonic change.
struct ActivityLED: View {
    let trigger: Int
    let color: Color
    @State private var lit = false

    var body: some View {
        Circle()
            .fill(lit ? color : color.opacity(0.18))
            .frame(width: 9, height: 9)
            .overlay(Circle().strokeBorder(color.opacity(0.4), lineWidth: 0.5))
            .shadow(color: lit ? color : .clear, radius: lit ? 3.5 : 0)
            .onChange(of: trigger) { _, _ in flash() }
            .accessibilityHidden(true)
    }

    private func flash() {
        lit = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
            withAnimation(.easeOut(duration: 0.2)) { lit = false }
        }
    }
}

// MARK: - Per-Dimension LED

/// LED + dimension number label. The label is rendered alongside the dot so
/// the user can tell at a glance which channel is firing without hovering.
private struct DimensionLED: View {
    let index: Int
    let trigger: Int
    let color: Color
    @State private var lit = false

    var body: some View {
        HStack(spacing: 3) {
            Circle()
                .fill(lit ? color : color.opacity(0.15))
                .frame(width: 8, height: 8)
                .overlay(Circle().strokeBorder(color.opacity(0.35), lineWidth: 0.5))
                .shadow(color: lit ? color : .clear, radius: lit ? 3 : 0)
            Text("\(index)")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .onChange(of: trigger) { _, _ in flash() }
        .accessibilityLabel("Dimension \(index)")
    }

    private func flash() {
        lit = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
            withAnimation(.easeOut(duration: 0.25)) { lit = false }
        }
    }
}

// MARK: - Dimension Fader

/// Horizontal slider for one input dimension. Idle, it follows `modelValue`
/// (the last value the RNN emitted for the matching output dimension). It is
/// driven red — detached from `modelValue` — by either of two user actions:
///   • Drag: the slider's value diverges and `onDrag` injects MIDI input.
///   • Live MIDI in: each mapped message bumps `inputTrigger`, snapping the
///     bar to `inputValue` so the user sees their playing reflected in CALL
///     mode, the same way the model drives it green in RESPONSE mode.
/// Either way the bar settles back to `modelValue` ~250 ms after the last
/// interaction.
private struct DimensionFader: View {
    let dimension: Int
    let modelValue: Float
    let inputValue: Float
    let inputTrigger: Int
    let outputTrigger: Int
    let onDrag: (Float) -> Void

    @State private var localValue: Float = 0
    @State private var dragActive: Bool = false
    @State private var inputActive: Bool = false
    @State private var dragEndTask: Task<Void, Never>?
    @State private var inputEndTask: Task<Void, Never>?

    var body: some View {
        // Custom binding so the setter fires *only* on user interaction with
        // the slider. Model-driven writes go through `onChange(of: modelValue)`
        // which mutates `localValue` directly — bypassing this setter, so we
        // never falsely mark them as drags. SwiftUI Slider's onEditingChanged
        // is unreliable on macOS (doesn't always fire false on mouse-up), so
        // we don't depend on it; the debounce below recovers the green state.
        let userBinding = Binding<Float>(
            get: { localValue },
            set: { newValue in
                localValue = newValue
                dragActive = true
                onDrag(newValue)
                scheduleDragEnd()
            }
        )

        return HStack(spacing: 8) {
            // Numbered LED badge — red flash on user input (live MIDI in or
            // slider drag, which loops back through inputTrigger via the
            // engine's input buffer), green flash on RNN output. Same flash
            // timing as the per-dim activity LEDs and mapping-row badges.
            DimensionBadge(dimensionIndex: dimension,
                           enabled: true,
                           inputTrigger:  inputTrigger,
                           outputTrigger: outputTrigger)

            // Red while the user is driving the model (drag or live MIDI in),
            // green while the bar is reflecting model output. Matches IN/OUT LEDs.
            SlimParameterBar(
                value: userBinding,
                range: 0...1,
                label: "Dimension \(dimension)",
                formattedValue: String(format: "%.2f", localValue),
                tint: userActive ? .red : .green,
                showsTickWhenIdle: false,
                hint: "Drives this dimension and sends MIDI input to IMPSY"
            )

            Text(String(format: "%.2f", localValue))
                .font(.system(.caption, design: .monospaced))
                .monospacedDigit()
                .frame(width: 38, alignment: .trailing)
                .foregroundStyle(userActive ? .red : .green)
        }
        .onChange(of: modelValue) { _, newValue in
            if !userActive { localValue = newValue }
        }
        // Live MIDI in: jump to the received value and show red, exactly as a
        // drag would. Ignored while the user is dragging — the drag position is
        // authoritative and the injected MIDI round-trips back here with a lag
        // that would otherwise stutter the bar.
        .onChange(of: inputTrigger) { _, _ in
            guard !dragActive else { return }
            localValue = inputValue
            inputActive = true
            scheduleInputEnd()
        }
        .task(id: dimension) {
            localValue = modelValue
        }
        .onDisappear {
            dragEndTask?.cancel()
            inputEndTask?.cancel()
        }
    }

    /// True whenever the user — not the model — is driving this dimension.
    private var userActive: Bool { dragActive || inputActive }

    /// End the drag (and snap back to the model's value) ~250 ms after the
    /// last user change — the debounce window that lets us handle a stream of
    /// drag deltas as one continuous interaction.
    private func scheduleDragEnd() {
        dragEndTask?.cancel()
        dragEndTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            dragActive = false
            if !inputActive { localValue = modelValue }
        }
    }

    /// Mirror of `scheduleDragEnd` for live MIDI input: a stream of mapped
    /// messages keeps the bar red and tracking until 250 ms after the last one.
    private func scheduleInputEnd() {
        inputEndTask?.cancel()
        inputEndTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            inputActive = false
            if !dragActive { localValue = modelValue }
        }
    }
}

// MARK: - Flow Layout

/// Minimal wrapping layout. SwiftUI's native HStack does not wrap; without
/// this, a high-dimensional model overflows the AUv3 view on iPhone widths.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rows: [[CGSize]] = [[]]
        var rowWidth: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            let next = rowWidth + (rows[rows.count - 1].isEmpty ? 0 : spacing) + s.width
            if next > maxWidth, !rows[rows.count - 1].isEmpty {
                rows.append([s])
                rowWidth = s.width
            } else {
                rows[rows.count - 1].append(s)
                rowWidth = next
            }
        }
        let height = rows.reduce(0) { acc, row in
            acc + (row.map(\.height).max() ?? 0) + (acc == 0 ? 0 : spacing)
        }
        let width = rows.map { row in
            row.reduce(0) { $0 + $1.width } + CGFloat(max(0, row.count - 1)) * spacing
        }.max() ?? 0
        return CGSize(width: min(width, maxWidth), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            v.place(at: CGPoint(x: x, y: y), proposal: .init(s))
            x += s.width + spacing
            rowHeight = max(rowHeight, s.height)
        }
    }
}
