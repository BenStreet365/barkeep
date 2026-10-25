import BarkeepCore
import SwiftUI

enum AppFilter: String, CaseIterable, Identifiable {
    case all = "All Apps"
    case updates = "Updates"
    var id: String { rawValue }

    func includes(_ record: AppRecord) -> Bool {
        switch self {
        case .all: true
        case .updates: record.available != nil
        }
    }
}

/// The full window: every app barkeep found, how it updates and where its update stands.
struct MainView: View {
    let model: BarModel
    @Bindable var selection: Selection
    let delegate: AppDelegate
    @State private var filter: AppFilter = .all
    @State private var search = ""
    @State private var sortOrder = [KeyPathComparator(\AppRecord.app.name, comparator: .localizedStandard)]

    var rows: [AppRecord] {
        model.apps.filter { filter.includes($0) }
            .filter { search.isEmpty || $0.app.name.localizedCaseInsensitiveContains(search) || $0.app.bundleIdentifier.localizedCaseInsensitiveContains(search) }
            .sorted(using: sortOrder)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            table
            // The selected app's details, under the table.
            if let path = selection.path, let record = model.apps.first(where: { $0.app.path == path }) {
                Divider()
                AppDetail(record: record, model: model, delegate: delegate)
                    .frame(height: 250)
            }
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Search apps")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Show", selection: $filter) {
                    ForEach(AppFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            ToolbarItem {
                Button {
                    model.checkNow()
                } label: {
                    Label("Check for Updates", systemImage: "arrow.clockwise")
                }
                .disabled(model.checking || !model.userUpdatesAllowed)
                .help(model.userUpdatesAllowed ? "Check every app's update feed now" : "Turned off by your administrator")
            }
        }
    }

    var header: some View {
        HStack(spacing: 12) {
            Image(systemName: model.waiting.isEmpty ? "checkmark.seal.fill" : "arrow.down.circle.fill")
                .font(.system(size: 28))
                .foregroundStyle(model.waiting.isEmpty ? .green : .accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.summary).font(.title3.weight(.semibold))
                Group {
                    if let state = model.state {
                        Text("\(state.apps.count) apps found · last checked \(state.lastCheck.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "never")")
                    } else {
                        Text("Waiting for the barkeep service (\(Daemon.label)) to report")
                    }
                }
                .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if let banner = model.banner {
                Text(banner).font(.callout).foregroundStyle(.secondary).lineLimit(2).frame(maxWidth: 320, alignment: .trailing)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    var table: some View {
        Table(rows, selection: $selection.path, sortOrder: $sortOrder) {
            TableColumn("App", value: \.app.name) { record in
                HStack(spacing: 6) {
                    AppIcon(path: record.app.path, size: 18)
                    Text(record.app.name.replacingOccurrences(of: ".app", with: ""))
                }
            }
            .width(min: 140, ideal: 200)
            TableColumn("Installed", value: \.app.displayVersion) { Text($0.app.displayVersion).monospacedDigit().help($0.app.displayVersion) }
                .width(min: 80, ideal: 130)
            TableColumn("Available") { record in Text(record.available?.displayVersion ?? "").monospacedDigit() }
                .width(min: 80, ideal: 110)
            TableColumn("Status", value: \.status.rawValue) { record in StatusLabel(status: record.status) }
            .width(min: 110, ideal: 130)
            TableColumn("Source") { record in Text(record.source?.definition.kind.rawValue ?? "—").foregroundStyle(.secondary) }
                .width(min: 70, ideal: 100)
            TableColumn("Location", value: \.app.path) { record in
                Text(location(record.app.path)).foregroundStyle(.secondary).help(record.app.path)
            }
            .width(min: 90, ideal: 130)
        }
    }

    /// The folder an app is in, short: "Applications", "~/Applications", "Applications/Utilities".
    func location(_ path: String) -> String {
        let folder = (path as NSString).deletingLastPathComponent
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if folder.hasPrefix(home + "/") { return "~" + folder.dropFirst(home.count) }
        let parts = folder.split(separator: "/").map(String.init)
        if parts.count >= 2, parts[0] == "Users" { return "\(parts[1])'s " + parts.dropFirst(2).joined(separator: "/") }
        return String(folder.dropFirst())
    }
}

/// A status in the table, coloured by kind. A selected row has a prominent background, where
/// the colours would be unreadable, so it takes the row's own text colour instead.
struct StatusLabel: View {
    let status: AppStatus
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        Label(status.label, systemImage: status.symbol)
            .foregroundStyle(prominence == .increased ? AnyShapeStyle(.primary) : AnyShapeStyle(color))
    }

    var color: Color {
        switch status {
        case .failed: .red
        case .closingSoon: .orange
        case .upToDate, .updated: .green
        case .waitingForQuit, .coolingOff, .installing: .accentColor
        default: .secondary
        }
    }
}

struct AppDetail: View {
    let record: AppRecord
    let model: BarModel
    let delegate: AppDelegate

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                AppIcon(path: record.app.path, size: 40)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(record.app.name.replacingOccurrences(of: ".app", with: "")).font(.title3.weight(.semibold))
                        Label(record.status.label, systemImage: record.status.symbol).font(.callout).foregroundStyle(.secondary)
                    }
                    Text(record.message).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if record.available != nil, model.userUpdatesAllowed, ![.coolingOff, .installing, .managedElsewhere].contains(record.status) {
                    Button(model.updating.contains(record.app.path) ? "Updating…" : "Update Now") { delegate.confirmAndUpdate(record) }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.updating.contains(record.app.path))
                }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([record.app.url]) }
            }
            ScrollView {
                HStack(alignment: .top, spacing: 24) {
                    section("Version") {
                        row("Installed", record.app.displayVersion)
                        if let available = record.available {
                            row("Available", available.displayVersion)
                            row("Released", available.releaseDate.map(date) ?? "Not in the feed")
                            row("Found", record.firstSeen.map(date))
                            row("Installs after", record.installableAfter.map(date))
                            row("Deadline", record.deadline.map(date) ?? "None")
                        }
                        row("Last updated", record.lastUpdated.map(date))
                        row("Previous", record.previousVersion)
                    }
                    section("Update source") {
                        if let source = record.source {
                            row("Type", source.definition.kind.rawValue)
                            row("Found from", source.evidence)
                            row("Feed", source.definition.feedURL ?? source.definition.repository)
                            row("Expected team", source.definition.expectedTeamIdentifier)
                            row("Last checked", record.lastChecked.map(date))
                        } else {
                            Text("Barkeep doesn't know where this app's updates come from. An administrator can add it to AppSources in the profile.")
                                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    section("Identity") {
                        row("Bundle ID", record.app.bundleIdentifier)
                        row("Location", record.app.path)
                        row("Team ID", record.app.teamID)
                        row("Architectures", record.app.metadata.architectures.joined(separator: ", "))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16)
    }

    func date(_ d: Date) -> String { d.formatted(date: .abbreviated, time: .shortened) }

    func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    @ViewBuilder func row(_ label: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            HStack(alignment: .firstTextBaseline) {
                Text(label).foregroundStyle(.secondary).frame(width: 96, alignment: .leading)
                Text(value).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            .font(.callout)
        }
    }
}
