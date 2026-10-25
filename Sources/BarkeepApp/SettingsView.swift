import BarkeepCore
import SwiftUI

/// The settings window. Every setting barkeep has is shown. What the organisation's profile sets
/// is locked; an administrator can change the rest for this Mac, which the daemon saves. The menu
/// bar icon and opening at login are each user's own choice, unless the profile sets them.
struct SettingsView: View {
    let model: BarModel
    let delegate: AppDelegate
    @State private var authorizer = SettingsAuthorizer()
    @State private var menuBar = true
    @State private var openAtLogin = true

    var config: Configuration { model.configuration }
    private typealias Key = Configuration.Key

    var body: some View {
        Form {
            Section("For you") {
                Toggle("Show Barkeep in the menu bar", isOn: Binding(get: { menuBar }, set: { menuBar = $0; delegate.setMenuBar($0) }))
                    .disabled(config.showInMenuBar != nil)
                if config.showInMenuBar != nil { ManagedNote() }
                Toggle("Open Barkeep at login", isOn: Binding(get: { openAtLogin }, set: { openAtLogin = $0; delegate.setOpenAtLogin($0) }))
                    .disabled(config.openAtLogin != nil)
                if config.openAtLogin != nil {
                    ManagedNote()
                } else if !openAtLogin {
                    Note("Apps can't be closed politely for their updates, and you won't be told before they are, while Barkeep isn't open.")
                }
            }

            Section {
                lockRow
            }

            Section("When updates install") {
                number(Key.coolingOffHours, "Cooling-off period", value: config.coolingOffHours, unit: "hours", range: 0...8760,
                       note: "How long an update must have been out before it's installed. \(hours(config.coolingOffHours)).")
                toggle(Key.enforceDeadlines, "Enforce deadlines", value: config.enforceDeadlines,
                       note: "Off: updates wait until their app quits, however long that takes.")
                number(Key.deadlineDays, "Deadline", value: config.deadlineDays, unit: "days", range: 0...365,
                       note: "After this, an app that's still open is asked to quit for its update.")
                row(Key.deadlineBasis) {
                    Picker("Deadline counts from", selection: Binding(
                        get: { config.deadlineBasis },
                        set: { send(Key.deadlineBasis, .string($0.rawValue)) })) {
                        Text("When the update was released").tag(DeadlineBasis.released)
                        Text("When Barkeep found it").tag(DeadlineBasis.discovered)
                    }
                }
                number(Key.deadlineGraceMinutes, "Warning before closing", value: config.deadlineGraceMinutes, unit: "minutes", range: 0...1440)
                toggle(Key.forceQuitAtDeadline, "Force apps to quit at the deadline", value: config.forceQuitAtDeadline,
                       note: "Off: an app that won't quit (an unsaved document, say) is asked again at the next check.")
                toggle(Key.relaunchAfterUpdate, "Reopen apps after updating them", value: config.relaunchAfterUpdate)
                number(Key.checkIntervalMinutes, "Check for updates every", value: config.checkIntervalMinutes, unit: "minutes", range: 15...10080)
            }

            Section("Which apps") {
                list(Key.excludedBundleIdentifiers, "Excluded apps", value: config.excludedBundleIdentifiers, placeholder: "None",
                     note: "Bundle IDs Barkeep leaves alone. com.microsoft.* matches a prefix.")
                list(Key.includedBundleIdentifiers, "Only these apps", value: config.includedBundleIdentifiers, placeholder: "All apps",
                     note: "If set, Barkeep manages only these bundle IDs.")
                list(Key.scanPaths, "Folders", value: config.scanPaths, placeholder: Configuration.defaultScanPaths.joined(separator: ", "),
                     note: "~ stands for every user's home folder.")
                profileOnly("Update sources", value: config.appSources.isEmpty ? "Barkeep's own" : "\(config.appSources.count) from the profile")
                profileOnly("Per-app rules", value: config.appSettings.isEmpty ? "None" : "\(config.appSettings.count) from the profile")
            }

            Section("Notifications") {
                toggle(Key.notifyUsers, "Tell people before closing their apps", value: config.notifyUsers)
                number(Key.notifyBeforeDeadlineHours, "First warning", value: config.notifyBeforeDeadlineHours, unit: "hours before", range: 0...720)
                toggle(Key.allowUserInitiatedUpdates, "Let people check for and install updates from Barkeep", value: config.allowUserInitiatedUpdates)
            }

            Section("Protection") {
                LabeledContent("Same developer as the installed app", value: "Always required")
                toggle(Key.requireGatekeeperAssessment, "Require Gatekeeper to accept each update", value: config.requireGatekeeperAssessment,
                       note: config.requireGatekeeperAssessment ? nil : "Updates that aren't notarised will be installed.")
                toggle(Key.allowPackageInstallers, "Allow installer packages", value: config.allowPackageInstallers,
                       note: "Only if signed by the app's own developer. Packages run their scripts as root.")
                number(Key.maximumDownloadSizeMB, "Largest download", value: config.maximumDownloadSizeMB, unit: "MB", range: 1...20480)
                list(Key.allowedTeamIdentifiers, "Allowed developers", value: config.allowedTeamIdentifiers, placeholder: "Any",
                     note: "If set, only apps signed by these Team IDs are updated.")
                if config.allowUnverifiedSignatures || config.allowFileURLs {
                    profileOnly("Testing switches", value: "On: signatures not issued by Apple or file URLs are accepted")
                }
            }

            Section("Barkeep's own updates") {
                toggle(Key.automaticSelfUpdates, "Install new versions of Barkeep automatically", value: config.automaticSelfUpdates)
                number(Key.selfUpdateDeferralDays, "Wait before installing them", value: config.selfUpdateDeferralDays, unit: "days",
                       range: 0...Configuration.maxSelfUpdateDeferralDays)
            }

            if !model.configurationWarnings.isEmpty {
                Section("Settings problems") {
                    ForEach(model.configurationWarnings, id: \.self) { Text($0).font(.caption) }
                }
            }
            Section {
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")
                Link("barkeep.street365.uk", destination: AppDelegate.website)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 520, idealWidth: 600, minHeight: 420, idealHeight: 720)
        .onAppear {
            menuBar = delegate.showsInMenuBar
            openAtLogin = delegate.opensAtLogin
        }
        .onDisappear { authorizer.lock() }
    }

    // MARK: The lock

    var editable: Set<String> { LocalSettings.editableKeys.subtracting(config.managedKeys) }

    @ViewBuilder var lockRow: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: authorizer.unlocked ? "lock.open.fill" : "lock.fill")
                .font(.title2).foregroundStyle(.secondary).frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                if editable.isEmpty {
                    Text("Your organisation sets all of Barkeep's settings.")
                } else if authorizer.unlocked {
                    Text("Changes apply to everyone on this Mac.")
                } else {
                    Text("An administrator's name and password are needed to change these settings.")
                }
                if !config.managedKeys.isEmpty, !editable.isEmpty {
                    Note("Settings marked “Set by your organisation” come from a configuration profile and can't be changed here.")
                }
                if let problem = authorizer.problem {
                    Text(problem).font(.caption).foregroundStyle(.red)
                }
            }
            Spacer()
            if !editable.isEmpty {
                if authorizer.unlocked {
                    VStack(alignment: .trailing) {
                        Button("Lock") { authorizer.lock() }
                        if !config.localKeys.isEmpty {
                            Button("Restore Defaults") {
                                for key in config.localKeys { authorizer.change(key, to: nil, model: model) }
                            }
                        }
                    }
                } else {
                    Button("Unlock…") { authorizer.unlock() }.disabled(authorizer.unlocking)
                }
            }
        }
    }

    // MARK: Rows

    func locked(_ key: String) -> Bool {
        config.managedKeys.contains(key) || !authorizer.unlocked || authorizer.saving.contains(key)
    }

    func send(_ key: String, _ value: LocalSettings.Value?) {
        authorizer.change(key, to: value, model: model)
    }

    @ViewBuilder func row<Content: View>(_ key: String, note: String? = nil, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            content().disabled(locked(key))
            if config.managedKeys.contains(key) {
                ManagedNote()
            } else if let note {
                Note(note)
            }
        }
    }

    func toggle(_ key: String, _ title: String, value: Bool, note: String? = nil) -> some View {
        row(key, note: note) {
            Toggle(title, isOn: Binding(get: { value }, set: { send(key, .bool($0)) }))
        }
    }

    func number(_ key: String, _ title: String, value: Int, unit: String, range: ClosedRange<Int>, note: String? = nil) -> some View {
        row(key, note: note) {
            NumberField(title: title, value: value, unit: unit, range: range) { send(key, .int($0)) }
        }
    }

    func list(_ key: String, _ title: String, value: [String], placeholder: String, note: String? = nil) -> some View {
        row(key, note: note) {
            ListField(title: title, value: value, placeholder: placeholder) { send(key, $0.isEmpty ? nil : .strings($0)) }
        }
    }

    func profileOnly(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent(title, value: value)
            Note("Set only by a configuration profile.")
        }
    }

    func hours(_ h: Int) -> String {
        if h == 0 { return "None" }
        if h % 24 == 0 { return "\(h / 24) day\(h == 24 ? "" : "s")" }
        return "\(h) hour\(h == 1 ? "" : "s")"
    }
}

private struct Note: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
}

private struct ManagedNote: View {
    var body: some View {
        Label("Set by your organisation", systemImage: "lock.fill").font(.caption).foregroundStyle(.secondary)
    }
}

/// A whole number, saved when the field is submitted or loses focus.
private struct NumberField: View {
    let title: String
    let value: Int
    let unit: String
    let range: ClosedRange<Int>
    let commit: (Int) -> Void
    @State private var draft = 0
    /// What was last sent, so Return and then losing focus send it once.
    @State private var sent: Int?
    @FocusState private var focused: Bool

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                TextField(title, value: $draft, format: .number.grouping(.never))
                    .labelsHidden().multilineTextAlignment(.trailing).frame(width: 70)
                    .focused($focused)
                    .onSubmit(save)
                Text(unit).foregroundStyle(.secondary)
            }
        }
        .onAppear { draft = value }
        .onChange(of: value) { draft = value; sent = nil }
        .onChange(of: focused) { if !focused { save() } }
    }

    func save() {
        let clamped = min(max(draft, range.lowerBound), range.upperBound)
        draft = clamped
        guard clamped != value, clamped != sent else { return }
        sent = clamped
        commit(clamped)
    }
}

/// A list of identifiers or folders, separated by commas or new lines.
private struct ListField: View {
    let title: String
    let value: [String]
    let placeholder: String
    let commit: ([String]) -> Void
    @State private var draft = ""
    @State private var sent: [String]?
    @FocusState private var focused: Bool

    var body: some View {
        LabeledContent(title) {
            TextField(title, text: $draft, prompt: Text(placeholder), axis: .vertical)
                .labelsHidden().lineLimit(1...4).frame(minWidth: 220)
                .focused($focused)
                .onSubmit(save)
        }
        .onAppear { draft = value.joined(separator: ", ") }
        .onChange(of: value) { draft = value.joined(separator: ", "); sent = nil }
        .onChange(of: focused) { if !focused { save() } }
    }

    func save() {
        let items = draft.split(whereSeparator: { $0 == "," || $0.isNewline }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard items != value, items != sent else { return }
        sent = items
        commit(items)
    }
}
