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
                Text(viewModel.modelStatus.displayString)
                    .font(.caption)
                    .foregroundStyle(statusColor)
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
            HStack(spacing: 0) {
                metric("Events", "\(viewModel.generatedEventCount)")
                Divider().frame(height: 30)
                metric("Δt", String(format: "%.3f s", viewModel.lastEventDt))
                Divider().frame(height: 30)
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
/// (the last value the RNN emitted for the matching output dimension). On
/// touch, the user drives it instead: the slider's local value diverges from
/// `modelValue` while dragging and calls `onDrag` so the view model can inject
/// MIDI input — closing the loop, the engine's next output event will refresh
/// `modelValue` and the fader will resume tracking once released.
private struct DimensionFader: View {
    let dimension: Int
    let modelValue: Float
    let onDrag: (Float) -> Void

    @State private var localValue: Float = 0
    @State private var dragActive: Bool = false
    @State private var dragEndTask: Task<Void, Never>?

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
            Text("\(dimension)")
                .font(.system(.caption, design: .monospaced, weight: .semibold))
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.primary.opacity(0.08)))

            Slider(value: userBinding, in: 0...1)
                .controlSize(.small)
                // Red while the user is driving the model (input), green while
                // the fader is reflecting model output. Matches the IN/OUT LEDs.
                .tint(dragActive ? .red : .green)

            Text(String(format: "%.2f", localValue))
                .font(.system(.caption, design: .monospaced))
                .monospacedDigit()
                .frame(width: 38, alignment: .trailing)
                .foregroundStyle(dragActive ? .red : .green)
        }
        .onChange(of: modelValue) { _, newValue in
            if !dragActive { localValue = newValue }
        }
        .task(id: dimension) {
            localValue = modelValue
        }
        .onDisappear { dragEndTask?.cancel() }
    }

    /// End the drag (and snap back to the model's value) ~250 ms after the
    /// last user change — the debounce window that lets us handle a stream of
    /// drag deltas as one continuous interaction.
    private func scheduleDragEnd() {
        dragEndTask?.cancel()
        dragEndTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            dragActive = false
            localValue = modelValue
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
