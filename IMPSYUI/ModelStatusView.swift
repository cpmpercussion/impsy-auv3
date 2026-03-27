import SwiftUI

struct ModelStatusView: View {
    @ObservedObject var viewModel: IMPSYViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(viewModel.modelName)
                        .font(.system(.subheadline, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(viewModel.modelStatus.displayString)
                        .font(.caption)
                        .foregroundStyle(statusColor)
                }
                Spacer()
                ModelPickerButton { url in viewModel.loadModel(url: url) }
                    .buttonStyle(.bordered)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
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
