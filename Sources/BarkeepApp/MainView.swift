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
    // The filter, the statuses hidden and the table's columns are remembered between launches.
    @AppStorage("AppFilter") private var filter: AppFilter = .all
    @AppStorage("HiddenStatuses") private var hiddenStatusList = [AppStatus.noSource, .managedElsewhere].map(\.rawValue).joined(separator: ",")
    @AppStorage("TableColumns") private var columnData = Data()
    @AppStorage("ShowsInspector") private var showsInspector = true
    @State private var search = ""
    @State private var sortOrder = [KeyPathComparator(\AppRecord.app.name, comparator: .localizedStandard)]

    var hiddenStatuses: Set<AppStatus> {
        Set(hiddenStatusList.split(separator: ",").compactMap { AppStatus(rawValue: String($0)) })
    }

    func shows(_ status: AppStatus) -> Binding<Bool> {
        Binding {
            !hiddenStatuses.contains(status)
        } set: { shown in
            var hidden = hiddenStatuses
            if shown { hidden.remove(status) } else { hidden.insert(status) }
            hiddenStatusList = AppStatus.allCases.filter(hidden.contains).map(\.rawValue).joined(separator: ",")
        }
    }

    /// Which columns are shown, their order and widths. Source and Location start hidden.
    var columns: Binding<TableColumnCustomization<AppRecord>> {
        Binding {
            (try? JSONDecoder().decode(TableColumnCustomization<AppRecord>.self, from: columnData)) ?? TableColumnCustomization()
        } set: {
            columnData = (try? JSONEncoder().encode($0)) ?? Data()
        }
    }

    func shows(column id: String, hiddenByDefault: Bool) -> Binding<Bool> {
        Binding {
            switch columns.wrappedValue[visibility: id] {
            case .visible: true
            case .hidden: false
            default: !hiddenByDefault
            }
        } set: {
            columns.wrappedValue[visibility: id] = $0 ? .visible : .hidden
        }
    }

    var rows: [AppRecord] {
        model.apps.filter { filter.includes($0) && !hiddenStatuses.contains($0.status) }
            .filter { search.isEmpty || $0.app.name.localizedCaseInsensitiveContains(search) || $0.app.bundleIdentifier.localizedCaseInsensitiveContains(search) }
            .sorted(using: sortOrder)
    }

    var selected: AppRecord? {
        selection.path.flatMap { path in model.apps.first { $0.app.path == path } }
    }

    var body: some View {
        table
            .overlay { if rows.isEmpty { emptyState } }
            // What a request to the daemon is doing, or why it failed.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let banner = model.banner { BannerBar(text: banner, working: model.checking || !model.updating.isEmpty) { model.banner = nil } }
            }
            // The selected app's details, in the standard trailing inspector.
            .inspector(isPresented: $showsInspector) {
                Group {
                    if let selected {
                        AppDetail(record: selected, model: model, delegate: delegate)
                    } else {
                        ContentUnavailableView("No App Selected", systemImage: "app.dashed",
                                               description: Text("Select an app to see how it updates and where its update stands."))
                    }
                }
                .inspectorColumnWidth(min: 280, ideal: 320, max: 460)
            }
            .navigationTitle("Barkeep")
            .navigationSubtitle(subtitle)
            .searchable(text: $search, placement: .toolbar, prompt: "Search apps")
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("Show", selection: $filter) {
                        ForEach(AppFilter.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .help("Show every app, or only those with an update")
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
                ToolbarItem {
                    filterMenu
                }
                ToolbarItem {
                    Button {
                        showsInspector.toggle()
                    } label: {
                        Label("Details", systemImage: "sidebar.trailing")
                    }
                    .help(showsInspector ? "Hide the selected app's details" : "Show the selected app's details")
                }
            }
    }

    /// Under the window's title: how the bar is.
    var subtitle: String {
        guard let state = model.state else { return "Waiting for Barkeep's service" }
        let checked = state.lastCheck.map { "checked \($0.formatted(.relative(presentation: .named)))" } ?? "not checked yet"
        return "\(model.summary) · \(checked)"
    }

    @ViewBuilder var emptyState: some View {
        if model.state == nil {
            ContentUnavailableView("Waiting for Barkeep's Service", systemImage: "hourglass",
                                   description: Text("The background service (\(Daemon.label)) hasn't reported yet. It starts with the Mac and looks for apps straight away."))
        } else if !search.isEmpty {
            ContentUnavailableView.search(text: search)
        } else if filter == .updates, !model.apps.contains(where: { filter.includes($0) }) {
            ContentUnavailableView("No Updates Waiting", systemImage: "checkmark.seal",
                                   description: Text("Every app Barkeep looks after is up to date."))
        } else {
            ContentUnavailableView("No Apps to Show", systemImage: "line.3.horizontal.decrease.circle",
                                   description: Text("The Filter menu is hiding every app here."))
        }
    }

    var filterMenu: some View {
        let hiddenCount = model.apps.filter { filter.includes($0) && hiddenStatuses.contains($0.status) }.count
        return Menu {
            Section("Show Apps That Are") {
                ForEach(AppStatus.allCases, id: \.self) { status in
                    Toggle(status.label, isOn: shows(status))
                }
            }
            Section("Columns") {
                Toggle("Source", isOn: shows(column: "source", hiddenByDefault: true))
                Toggle("Location", isOn: shows(column: "location", hiddenByDefault: true))
            }
        } label: {
            Label("Filter", systemImage: hiddenStatuses.isEmpty ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
        }
        .help(hiddenCount == 0 ? "Choose which apps and columns to show" : "\(hiddenCount) apps hidden by the filter")
    }

    var table: some View {
        Table(rows, selection: $selection.path, sortOrder: $sortOrder, columnCustomization: columns) {
            TableColumn("App", value: \.app.name) { record in
                HStack(spacing: 6) {
                    AppIcon(path: record.app.path, size: 18)
                    Text(record.app.displayName)
                }
            }
            .width(min: 140, ideal: 200)
            .customizationID("app")
            .disabledCustomizationBehavior(.visibility)
            TableColumn("Installed", value: \.app.displayVersion) { Text($0.app.displayVersion).monospacedDigit().help($0.app.displayVersion) }
                .width(min: 80, ideal: 130)
                .customizationID("installed")
            TableColumn("Available") { record in Text(record.available?.displayVersion ?? "").monospacedDigit() }
                .width(min: 80, ideal: 110)
                .customizationID("available")
            TableColumn("Status", value: \.status.rawValue) { record in StatusLabel(status: record.status) }
            .width(min: 110, ideal: 130)
            .customizationID("status")
            TableColumn("Source") { record in Text(record.source?.definition.kind.rawValue ?? "—").foregroundStyle(.secondary) }
                .width(min: 70, ideal: 100)
                .customizationID("source")
                .defaultVisibility(.hidden)
            TableColumn("Location", value: \.app.path) { record in
                Text(location(record.app.path)).foregroundStyle(.secondary).help(record.app.path)
            }
            .width(min: 90, ideal: 130)
            .customizationID("location")
            .defaultVisibility(.hidden)
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

/// What a request to the daemon is doing, or why it failed, along the bottom of the window.
struct BannerBar: View {
    let text: String
    let working: Bool
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if working {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            }
            Text(text).font(.callout).lineLimit(2).textSelection(.enabled)
            Spacer()
            if !working {
                Button("Dismiss", systemImage: "xmark", action: dismiss)
                    .labelStyle(.iconOnly).buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

/// The inspector: one app, how it updates and where its update stands.
struct AppDetail: View {
    let record: AppRecord
    let model: BarModel
    let delegate: AppDelegate
    @AppStorage("ShowsMoreInfo") private var showsMoreInfo = false

    var canUpdate: Bool {
        record.available != nil && model.userUpdatesAllowed && ![.coolingOff, .installing, .managedElsewhere].contains(record.status)
    }

    /// The release that will be installed, when it isn't the newest one.
    var next: AvailableUpdate? {
        guard let selected = record.selected, let available = record.available, !selected.isSameRelease(as: available) else { return nil }
        return selected
    }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        AppIcon(path: record.app.path, size: 48)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(record.app.displayName).font(.title3.weight(.semibold)).lineLimit(2)
                            StatusLabel(status: record.status).font(.callout)
                        }
                    }
                    Text(record.message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        if canUpdate {
                            Button(model.updating.contains(record.app.path) ? "Updating…" : "Update Now") { delegate.confirmAndUpdate(record) }
                                .buttonStyle(.borderedProminent)
                                .disabled(model.updating.contains(record.app.path))
                        }
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([record.app.url]) }
                    }
                }
            }
            Section("Version") {
                row("Installed", record.app.displayVersion)
                if let available = record.available {
                    row("Available", available.displayVersion)
                    if let next {
                        row("Installing next", next.displayVersion)
                        Text("This app releases often. Barkeep installs the newest release that has finished cooling off, then moves on to the next.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    row("Released", (next ?? available).releaseDate.map(date) ?? "Not in the feed")
                    row("Found", record.firstSeen.map(date))
                    row("Installs after", record.installableAfter.map(date))
                    row("Deadline", record.deadline.map(date) ?? "None")
                }
                row("Last updated", record.lastUpdated.map(date))
                row("Previous", record.previousVersion)
            }
            // Where its updates come from and what it is: there when wanted, out of the way otherwise.
            Section {
                Button {
                    withAnimation { showsMoreInfo.toggle() }
                } label: {
                    HStack {
                        Text("More Info")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                            .rotationEffect(.degrees(showsMoreInfo ? 90 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(showsMoreInfo ? "Expanded" : "Collapsed")
                .help(showsMoreInfo ? "Hide the update source and identity" : "Show the update source and identity")
            }
            if showsMoreInfo {
                Section("Update Source") {
                    if let source = record.source {
                        row("Type", source.definition.kind.rawValue)
                        row("Found from", source.evidence)
                        row("Feed", source.definition.feedURL ?? source.definition.repository)
                        row("Expected team", source.definition.expectedTeamIdentifier)
                        row("Last checked", record.lastChecked.map(date))
                    } else {
                        Text("Barkeep doesn't know where this app's updates come from. An administrator can add it to AppSources in the profile.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                Section("Identity") {
                    row("Bundle ID", record.app.bundleIdentifier)
                    row("Location", record.app.path)
                    row("Team ID", record.app.teamID)
                    row("Architectures", record.app.metadata.architectures.joined(separator: ", "))
                }
            }
        }
        .formStyle(.grouped)
    }

    func date(_ d: Date) -> String { d.formatted(date: .abbreviated, time: .shortened) }

    @ViewBuilder func row(_ label: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            LabeledContent(label) {
                Text(value).textSelection(.enabled).multilineTextAlignment(.trailing)
            }
        }
    }
}

extension InstalledApp {
    /// The app's name as Finder shows it, without ".app".
    var displayName: String {
        name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }
}
