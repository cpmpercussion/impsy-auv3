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
