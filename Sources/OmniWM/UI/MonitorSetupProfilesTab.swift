// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import SwiftUI

struct MonitorSetupProfilesTab: View {
    @Bindable var settings: SettingsStore
    @Bindable var controller: WMController

    @State private var connectedMonitors: [Monitor] = Monitor.current()
    @State private var editingProfile: MonitorSetupProfile?

    private var currentSignature: String {
        MonitorSetupProfile.computeSignature(from: connectedMonitors)
    }

    private var currentIsMatch: Bool {
        settings.activeSetupProfile(for: connectedMonitors) != nil
    }

    var body: some View {
        Form {
            Section("Current Setup") {
                LabeledContent("Monitors", value: connectedMonitors.map(\.name).joined(separator: " + "))
                LabeledContent("Signature", value: currentSignature.isEmpty ? "(none)" : currentSignature)
                    .font(.system(.caption, design: .monospaced))
                HStack {
                    if currentIsMatch {
                        Label("This setup has a matching profile", systemImage: "checkmark.circle.fill")
                            .foregroundColor(.green)
                    } else {
                        Button("Create Profile from Current Setup") {
                            createProfileFromCurrentSetup()
                        }
                        .disabled(currentSignature.isEmpty)
                    }
                    Spacer()
                }
            }

            Section {
                if settings.monitorSetupProfiles.isEmpty {
                    Text("No setup profiles configured")
                        .foregroundColor(.secondary)
                        .italic()
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 8)
                } else {
                    ForEach(settings.monitorSetupProfiles) { profile in
                        MonitorSetupProfileRow(
                            profile: profile,
                            isActive: profile.monitorSignature == currentSignature,
                            onEdit: { editingProfile = profile },
                            onDelete: { deleteProfile(profile) }
                        )
                    }
                }
            } header: {
                Text("Setup Profiles")
            } footer: {
                Text(
                    "Setup profiles let you use different layout and gap settings based on which monitors are connected. "
                        + "Create a profile for each arrangement you use (e.g. laptop only, laptop + external at home, etc.)."
                )
                .font(.caption)
                .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .sheet(item: $editingProfile) { profile in
            MonitorSetupProfileEditSheet(
                profile: profile,
                onSave: { updated in
                    updateProfile(updated)
                    editingProfile = nil
                },
                onCancel: { editingProfile = nil }
            )
        }
    }

    private func createProfileFromCurrentSetup() {
        let profile = MonitorSetupProfile(
            name: defaultProfileName(),
            monitorSignature: currentSignature
        )
        settings.monitorSetupProfiles.append(profile)
    }

    private func updateProfile(_ profile: MonitorSetupProfile) {
        if let index = settings.monitorSetupProfiles.firstIndex(where: { $0.id == profile.id }) {
            settings.monitorSetupProfiles[index] = profile
        }
    }

    private func deleteProfile(_ profile: MonitorSetupProfile) {
        settings.monitorSetupProfiles.removeAll { $0.id == profile.id }
    }

    private func defaultProfileName() -> String {
        let count = settings.monitorSetupProfiles.count + 1
        return "Setup \(count)"
    }
}

private struct MonitorSetupProfileRow: View {
    let profile: MonitorSetupProfile
    let isActive: Bool
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(profile.name)
                        .font(.body.weight(.medium))
                    if isActive {
                        Text("Active")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.green.opacity(0.15))
                            .foregroundColor(.green)
                            .cornerRadius(4)
                    }
                }
                Text(profile.monitorSignature)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            if let layoutType = profile.defaultLayoutType {
                Text(layoutType.displayName)
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.1))
                    .cornerRadius(4)
            }

            if profile.gapSize != nil {
                Text("\(Int(profile.gapSize!)) px")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Button(action: onEdit) {
                Label("Edit \(profile.name)", systemImage: "pencil.circle")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.plain)
            .help("Edit setup profile")
            .accessibilityLabel("Edit \(profile.name)")

            Button(action: onDelete) {
                Label("Delete \(profile.name)", systemImage: "trash.circle")
                    .labelStyle(.iconOnly)
                    .foregroundColor(.red)
            }
            .buttonStyle(.plain)
            .help("Delete setup profile")
            .accessibilityLabel("Delete \(profile.name)")
        }
        .padding(.vertical, 4)
    }
}

private struct MonitorSetupProfileEditSheet: View {
    @State private var profile: MonitorSetupProfile
    let onSave: (MonitorSetupProfile) -> Void
    let onCancel: () -> Void

    init(
        profile: MonitorSetupProfile,
        onSave: @escaping (MonitorSetupProfile) -> Void,
        onCancel: @escaping () -> Void
    ) {
        _profile = State(initialValue: profile)
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("Edit Setup Profile")
                .font(.headline)

            Form {
                TextField("Name", text: $profile.name)

                Picker("Layout Algorithm", selection: $profile.defaultLayoutType) {
                    Text("Use Global Default").tag(LayoutType?.none)
                    ForEach(LayoutType.allCases.filter { $0 != .defaultLayout }) { layout in
                        Text(layout.displayName).tag(LayoutType?.some(layout))
                    }
                }

                HStack {
                    Text("Gap Size")
                    Spacer()
                    Toggle("", isOn: gapSizeEnabled)
                        .labelsHidden()
                    if profile.gapSize != nil {
                        TextField("", value: gapSizeBinding, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 60)
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") { onSave(profile) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 420, height: 280)
    }

    private var gapSizeEnabled: Binding<Bool> {
        Binding(
            get: { profile.gapSize != nil },
            set: { enabled in
                profile.gapSize = enabled ? 16 : nil
            }
        )
    }

    private var gapSizeBinding: Binding<Double> {
        Binding(
            get: { profile.gapSize ?? 16 },
            set: { profile.gapSize = $0 }
        )
    }
}
