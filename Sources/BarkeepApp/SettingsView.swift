import BarkeepCore
import SwiftUI

/// The settings window. Almost everything is set by the organisation's profile, so this mostly
/// shows the policy in plain words; the menu bar icon and opening at login are the user's choice
/// unless the profile sets them.
struct SettingsView: View {
    let model: BarModel
    let delegate: AppDelegate
    @State private var menuBar = true
    @State private var openAtLogin = true

    var config: Configuration { model.configuration }
    var managed: Bool { config.sources != ["defaults"] }

    var body: some View {
        Form {
            Section {
                Toggle("Show Barkeep in the menu bar", isOn: Binding(get: { menuBar }, set: { menuBar = $0; delegate.setMenuBar($0) }))
                    .disabled(config.showInMenuBar != nil)
                if config.showInMenuBar != nil {
                    Text("Set by your organisation").font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Open Barkeep at login", isOn: Binding(get: { openAtLogin }, set: { openAtLogin = $0; delegate.setOpenAtLogin($0) }))
                    .disabled(config.openAtLogin != nil)
                if config.openAtLogin != nil {
                    Text("Set by your organisation").font(.caption).foregroundStyle(.secondary)
                } else if !openAtLogin {
                    Text("Apps can't be closed politely for their updates, and you won't be told before they are, while Barkeep isn't open.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section(managed ? "Update policy (set by your organisation)" : "Update policy (defaults)") {
                LabeledContent("Cooling-off period", value: hours(config.coolingOffHours))
                LabeledContent("Deadline", value: config.enforceDeadlines
                               ? "\(config.deadlineDays) day\(config.deadlineDays == 1 ? "" : "s") after an update is \(config.deadlineBasis == .released ? "released" : "found")"
                               : "None: updates wait until apps quit")
                if config.enforceDeadlines {
                    LabeledContent("Warning before closing", value: "\(config.deadlineGraceMinutes) minutes")
                }
                LabeledContent("Checks for updates", value: "Every \(hours(config.checkIntervalMinutes / 60, minutes: config.checkIntervalMinutes % 60))")
                LabeledContent("Excluded apps", value: config.excludedBundleIdentifiers.isEmpty ? "None" : config.excludedBundleIdentifiers.joined(separator: ", "))
                LabeledContent("Folders", value: config.scanPaths.joined(separator: ", "))
            }
            Section("Protection") {
                LabeledContent("Same developer", value: "Required")
                LabeledContent("Gatekeeper", value: config.requireGatekeeperAssessment ? "Required" : "Off")
                LabeledContent("Installer packages", value: config.allowPackageInstallers ? "Allowed if signed by the app's developer" : "Not allowed")
                if !config.allowedTeamIdentifiers.isEmpty {
                    LabeledContent("Allowed developers", value: config.allowedTeamIdentifiers.joined(separator: ", "))
                }
            }
            if !model.configurationWarnings.isEmpty {
                Section("Profile problems") {
                    ForEach(model.configurationWarnings, id: \.self) { Text($0).font(.caption) }
                }
            }
            Section {
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")
                Link("barkeep.street365.uk", destination: AppDelegate.website)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .onAppear {
            menuBar = delegate.showsInMenuBar
            openAtLogin = delegate.opensAtLogin
        }
    }

    func hours(_ h: Int, minutes: Int = 0) -> String {
        if h == 0 && minutes == 0 { return "None" }
        if h == 0 { return "\(minutes) minutes" }
        if h % 24 == 0 && minutes == 0 { return "\(h / 24) day\(h == 24 ? "" : "s")" }
        return "\(h) hour\(h == 1 ? "" : "s")\(minutes > 0 ? " \(minutes) min" : "")"
    }
}
