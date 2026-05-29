import SwiftUI

struct BindingView: View {
    @Environment(AppModel.self) private var model
    @State private var pairingURLText = ""
    @State private var parseError: String?
    @State private var isShowingScanner = false

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Pair Computer") {
                TextField("https://nudgecode.dev/pair?code=...", text: $pairingURLText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                Button {
                    if model.parsePairingURL(pairingURLText) {
                        parseError = nil
                    } else {
                        parseError = "Invalid pairing URL"
                    }
                } label: {
                    Label("Read Pairing URL", systemImage: "qrcode")
                }
                Button {
                    isShowingScanner = true
                } label: {
                    Label("Scan QR Code", systemImage: "qrcode.viewfinder")
                }
                if let parseError {
                    Text(parseError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }

            if let draft = model.bindingDraft {
                Section("Pending Claim") {
                    LabeledContent("Relay", value: draft.relayURL.absoluteString)
                    LabeledContent("Code", value: draft.code)
                    Button {
                        Task {
                            await model.claimDraftBinding()
                        }
                    } label: {
                        if model.bindingClaimState.isClaiming {
                            Label("Claiming", systemImage: "hourglass")
                        } else {
                            Label("Claim And Wait", systemImage: "link.badge.plus")
                        }
                    }
                    .disabled(model.bindingClaimState.isClaiming)
                    if case .failed(let message) = model.bindingClaimState {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }

            Section("Phone Profile") {
                Stepper("Rows \(model.phoneProfile.rows)", value: $model.phoneProfile.rows, in: 20 ... 60)
                Stepper("Columns \(model.phoneProfile.cols)", value: $model.phoneProfile.cols, in: 32 ... 120)
            }
        }
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
