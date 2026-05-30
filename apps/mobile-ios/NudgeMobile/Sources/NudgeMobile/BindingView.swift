import SwiftUI

struct BindingView: View {
    @Environment(AppModel.self) private var model
    @State private var pairingURLText = ""
    @State private var parseError: String?
    @State private var isShowingScanner = false

    var body: some View {
        @Bindable var model = model
        ScrollView {
            VStack(spacing: 24) {
                // Hero badge
                PillBadge(text: "BIND COMPUTER")
                    .padding(.top, 8)

                // Section: Pair Computer
                SectionCard(title: "Pair Computer") {
                    VStack(spacing: 12) {
                        // URL input field
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Pairing URL")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(Color.textMuted)
                            TextField("", text: $pairingURLText, prompt: Text("https://nudgecode.dev/pair?code=...")
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(Color.textSubtle))
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .keyboardType(.URL)
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(Color.textPrimary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .background(Color.surface2)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .strokeBorder(Color.borderBright, lineWidth: 1)
                                )
                        }

                        if let parseError {
                            HStack(spacing: 6) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.caption)
                                Text(parseError)
                                    .font(.system(.footnote, design: .monospaced))
                            }
                            .foregroundStyle(Color.danger)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        HStack(spacing: 10) {
                            // Read URL button (secondary style)
                            Button {
                                if model.parsePairingURL(pairingURLText) {
                                    self.parseError = nil
                                } else {
                                    self.parseError = "Invalid pairing URL"
                                }
                            } label: {
                                Label("Read URL", systemImage: "qrcode")
                                    .font(.system(.subheadline, design: .monospaced).weight(.medium))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 10)
                            }
                            .buttonStyle(SecondaryActionButtonStyle())

                            // Scan QR Code button (primary / accent style)
                            Button {
                                isShowingScanner = true
                            } label: {
                                Label("Scan QR", systemImage: "qrcode.viewfinder")
                                    .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 10)
                            }
                            .buttonStyle(AccentActionButtonStyle())
                        }
                    }
                }

                // Section: Pending Claim
                if let draft = model.bindingDraft {
                    SectionCard(title: "Pending Claim", accent: true) {
                        VStack(spacing: 12) {
                            LabeledCodeRow(label: "Relay", value: draft.relayURL.absoluteString)
                            Divider()
                                .background(Color.border)
                            LabeledCodeRow(label: "Code", value: draft.code)

                            if case .failed(let message) = model.bindingClaimState {
                                HStack(spacing: 6) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .font(.caption)
                                    Text(message)
                                        .font(.system(.footnote, design: .monospaced))
                                }
                                .foregroundStyle(Color.danger)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }

                            Button {
                                Task {
                                    await model.claimDraftBinding()
                                }
                            } label: {
                                Group {
                                    if model.bindingClaimState.isClaiming {
                                        Label("Claiming…", systemImage: "hourglass")
                                    } else {
                                        Label("Claim And Wait", systemImage: "link.badge.plus")
                                    }
                                }
                                .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                            }
                            .buttonStyle(AccentActionButtonStyle())
                            .disabled(model.bindingClaimState.isClaiming)
                        }
                    }
                }

                // Section: Phone Profile
                SectionCard(title: "Phone Profile") {
                    @Bindable var model = model
                    VStack(spacing: 8) {
                        ProfileStepperRow(label: "Rows", value: $model.phoneProfile.rows, range: 20...60)
                        Divider().background(Color.border)
                        ProfileStepperRow(label: "Columns", value: $model.phoneProfile.cols, range: 32...120)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 32)
        }
        .background(HeroBackground())
        .navigationTitle("Bind Computer")
        .sheet(isPresented: $isShowingScanner) {
            NavigationStack {
                QRCodeScannerView { value in
                    pairingURLText = value
                    if model.parsePairingURL(value) {
                        parseError = nil
                        isShowingScanner = false
                    } else {
                        parseError = "Invalid pairing QR code"
                    }
                } onError: { error in
                    parseError = error.message
                    isShowingScanner = false
                }
                .ignoresSafeArea()
                .navigationTitle("Scan Pairing Code")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Cancel") {
                            isShowingScanner = false
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Supporting components

/// Dark surface card with optional accent glow border.
private struct SectionCard<Content: View>: View {
    var title: String
    var accent: Bool = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title.uppercased())
                .font(.system(.caption2, design: .monospaced).weight(.semibold))
                .foregroundStyle(Color.textSubtle)
                .kerning(1.2)

            VStack(spacing: 0) {
                content()
                    .padding(14)
            }
            .background(accent ? Color.surface : Color.surface)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(
                        accent ? Color.accent.opacity(0.30) : Color.border,
                        lineWidth: 1
                    )
            )
            .shadow(color: accent ? Color.accentGlow : Color.clear, radius: 20, x: 0, y: 0)
        }
    }
}

/// A labeled row showing a monospaced code value.
private struct LabeledCodeRow: View {
    var label: String
    var value: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(Color.textMuted)
                .frame(width: 52, alignment: .leading)
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(Color.accent)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(3)
        }
    }
}

/// Compact stepper row for phone-profile settings.
private struct ProfileStepperRow: View {
    var label: String
    @Binding var value: Int
    var range: ClosedRange<Int>

    var body: some View {
        HStack {
            Text(label)
                .font(.system(.subheadline, design: .monospaced))
                .foregroundStyle(Color.textPrimary)
            Spacer()
            Text("\(value)")
                .font(.system(.body, design: .monospaced).weight(.semibold))
                .foregroundStyle(Color.accent)
                .frame(minWidth: 36, alignment: .center)
            Stepper("", value: $value, in: range)
                .labelsHidden()
                .tint(Color.accent)
        }
    }
}

/// Secondary (dark border) button style.
private struct SecondaryActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color.textMuted)
            .background(Color.surface2)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.borderBright, lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.7 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

/// Primary emerald accent button style (mirrors landing CTA).
private struct AccentActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color(hex: "#080b0f"))
            .background(Color.accent)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .opacity(configuration.isPressed ? 0.85 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}
