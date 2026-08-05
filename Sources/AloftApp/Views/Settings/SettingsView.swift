import SwiftUI

struct SettingsView: View {
    @AppStorage(MenuBarIconPreference.storageKey)
    private var menuBarIconRawValue =
        MenuBarIconPreference.defaultChoice.rawValue
    @AppStorage(TerminalFontPreference.familyStorageKey)
    private var terminalFontFamily =
        TerminalFontPreference.defaultFamily
    @AppStorage(TerminalFontPreference.sizeStorageKey)
    private var terminalFontSize =
        TerminalFontPreference.defaultSize

    var body: some View {
        Form {
            Section {
                HStack(spacing: 18) {
                    Image(
                        systemName: selectedChoice.systemName
                    )
                    .font(.system(size: 26, weight: .semibold))
                    .frame(width: 48, height: 48)
                    .background(.tint.opacity(0.12), in: .rect(cornerRadius: 12))

                    Picker(
                        L10n.string("Menu Bar Icon"),
                        selection: $menuBarIconRawValue
                    ) {
                        ForEach(MenuBarIconChoice.allCases) { choice in
                            Label(
                                choice.accessibilityTitle,
                                systemImage: choice.systemName
                            )
                            .labelStyle(.iconOnly)
                            .tag(choice.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            } header: {
                Text(L10n.string("Appearance"))
            }

            Section {
                Picker(
                    L10n.string("Font"),
                    selection: $terminalFontFamily
                ) {
                    Text(L10n.string("System Monospaced"))
                        .tag(
                            TerminalFontPreference
                                .systemFamilyIdentifier
                        )
                    ForEach(
                        TerminalFontPreference.availableFamilies,
                        id: \.self
                    ) { family in
                        Text(family)
                            .tag(family)
                    }
                }

                Stepper(
                    value: $terminalFontSize,
                    in: TerminalFontPreference
                        .supportedSizeRange,
                    step: 1
                ) {
                    LabeledContent(
                        L10n.string("Font Size"),
                        value: terminalFontSize.formatted(
                            .number.precision(
                                .fractionLength(0)
                            )
                        )
                    )
                }

                Text("Aa Bb 0123  ~/  $")
                    .font(Font(resolvedTerminalFont))
                    .frame(
                        maxWidth: .infinity,
                        alignment: .leading
                    )
                    .padding(10)
                    .background(
                        .quaternary,
                        in: RoundedRectangle(
                            cornerRadius: 8,
                            style: .continuous
                        )
                    )
            } header: {
                Text(L10n.string("Terminal"))
            }
        }
        .formStyle(.grouped)
        .frame(width: 430)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var selectedChoice: MenuBarIconChoice {
        MenuBarIconPreference.resolve(menuBarIconRawValue)
    }

    private var resolvedTerminalFont: NSFont {
        TerminalFontPreference.resolve(
            family: terminalFontFamily,
            size: terminalFontSize
        )
    }
}

private extension MenuBarIconChoice {
    var accessibilityTitle: String {
        switch self {
        case .bolt:
            "Aloft"
        case .terminal:
            L10n.string("Terminal")
        case .command:
            L10n.string("Command")
        case .play:
            L10n.string("Start")
        }
    }
}
