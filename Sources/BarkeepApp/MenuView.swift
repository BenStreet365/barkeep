import BarkeepCore
import SwiftUI

/// The menu bar popover: how the bar is, what's waiting, and a way into the full window.
struct MenuView: View {
    let model: BarModel
    let delegate: AppDelegate

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: model.waiting.isEmpty ? "checkmark.seal.fill" : "arrow.down.circle.fill")
                    .font(.title2)
                    .foregroundStyle(model.waiting.isEmpty ? .green : .accentColor)
                Text(model.summary).font(.headline)
            }

            if !model.waiting.isEmpty {
                Divider()
                ForEach(model.waiting.prefix(8)) { record in
                    WaitingRow(record: record, model: model, delegate: delegate)
                }
                if model.waiting.count > 8 {
                    Text("and \(model.waiting.count - 8) more…").font(.caption).foregroundStyle(.secondary)
                }
            }

            if let banner = model.banner {
                Text(banner).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            HStack {
                if model.userUpdatesAllowed {
                    Button(model.checking ? "Checking…" : "Check for Updates") { model.checkNow() }
                        .disabled(model.checking)
                }
                Spacer()
                Button("Open Barkeep") { delegate.showMainWindow() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 340)
    }
}

struct WaitingRow: View {
    let record: AppRecord
    let model: BarModel
    let delegate: AppDelegate

    var body: some View {
        HStack(spacing: 8) {
            AppIcon(path: record.app.path, size: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(record.app.name.replacingOccurrences(of: ".app", with: "")).lineLimit(1)
                Text(detail).font(.caption).foregroundStyle(record.status == .closingSoon ? .orange : .secondary).lineLimit(2)
            }
            Spacer()
            if model.userUpdatesAllowed, record.status != .coolingOff, record.status != .installing {
                Button(model.updating.contains(record.app.path) ? "…" : "Update") { delegate.confirmAndUpdate(record) }
                    .controlSize(.small)
                    .disabled(model.updating.contains(record.app.path))
            }
        }
    }

    var detail: String {
        let version = "\(record.app.displayVersion) → \(record.available?.displayVersion ?? "?")"
        switch record.status {
        case .coolingOff: return "\(version) · after \(record.installableAfter.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "")"
        case .closingSoon: return "\(version) · closes \(record.closeAt.map { $0.formatted(date: .omitted, time: .shortened) } ?? "soon")"
        case .waitingForQuit: return "\(version) · when it quits"
        case .installing: return "\(version) · installing"
        case .failed: return record.message
        default: return version
        }
    }
}

/// The Finder icon of an app.
struct AppIcon: View {
    let path: String
    let size: CGFloat

    var body: some View {
        Image(nsImage: NSWorkspace.shared.icon(forFile: path))
            .resizable()
            .frame(width: size, height: size)
    }
}
