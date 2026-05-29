import SwiftUI

struct BindingView: View {
    @Environment(AppModel.self) private var model
    @State private var pairingURLText = ""
    @State private var parseError: String?

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
                        model.claimDraftBinding()
                    } label: {
                        Label("Claim And Wait", systemImage: "link.badge.plus")
                    }
                }
            }

            Section("Phone Profile") {
                Stepper("Rows \(model.phoneProfile.rows)", value: $model.phoneProfile.rows, in: 20 ... 60)
                Stepper("Columns \(model.phoneProfile.cols)", value: $model.phoneProfile.cols, in: 32 ... 120)
            }
        }
        .navigationTitle("Bind")
    }
}
