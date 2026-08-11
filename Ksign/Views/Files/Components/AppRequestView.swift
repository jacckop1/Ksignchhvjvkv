//
//  AppRequestView.swift
//  Ksign
//

import SwiftUI

struct AppRequestView: View {
    @Binding var isPresented: Bool
    @Binding var appName: String
    @Binding var appLink: String
    @Binding var appFeatures: String

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Image(systemName: "gamecontroller.fill")
                            .foregroundStyle(.accent)
                        TextField("اسم اللعبة أو التطبيق", text: $appName)
                            .environment(\.layoutDirection, .rightToLeft)
                    }
                } header: {
                    Text("اسم التطبيق / اللعبة *")
                } footer: {
                    Text("مطلوب")
                        .foregroundStyle(.red)
                        .opacity(appName.isEmpty ? 1 : 0)
                }

                Section {
                    HStack {
                        Image(systemName: "link")
                            .foregroundStyle(.accent)
                        TextField("مثال: https://apps.apple.com/...", text: $appLink)
                            .keyboardType(.URL)
                            .autocapitalization(.none)
                    }
                } header: {
                    Text("رابط التطبيق (اختياري)")
                }

                Section {
                    ZStack(alignment: .topLeading) {
                        if appFeatures.isEmpty {
                            Text("اكتب التعديلات أو الإضافات المطلوبة...")
                                .foregroundStyle(.secondary)
                                .padding(.top, 8)
                                .padding(.leading, 4)
                                .environment(\.layoutDirection, .rightToLeft)
                        }
                        TextEditor(text: $appFeatures)
                            .frame(minHeight: 100)
                            .environment(\.layoutDirection, .rightToLeft)
                    }
                } header: {
                    Text("مميزات التعديل (اختياري)")
                }

                Section {
                    Button {
                        _sendRequest()
                    } label: {
                        HStack {
                            Spacer()
                            Image(systemName: "paperplane.fill")
                            Text("إرسال الطلب")
                                .fontWeight(.semibold)
                            Spacer()
                        }
                    }
                    .foregroundStyle(
                        appName.isEmpty
                            ? Color.secondary
                            : Color.white
                    )
                    .listRowBackground(
                        appName.isEmpty
                            ? Color(uiColor: .tertiarySystemFill)
                            : Color.accentColor
                    )
                    .disabled(appName.isEmpty)
                }
            }
            .navigationTitle("طلب تطبيق أو لعبة")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("إلغاء") {
                        isPresented = false
                    }
                }
            }
            .environment(\.layoutDirection, .rightToLeft)
        }
    }

    private func _sendRequest() {
        guard !appName.isEmpty else { return }

        let msg = """
        طلب تطبيق جديد

        اسم التطبيق: \(appName)
        رابط التطبيق: \(appLink.isEmpty ? "—" : appLink)
        ملاحظات / مميزات مطلوبة: \(appFeatures.isEmpty ? "—" : appFeatures)
        """

        let encoded = msg.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let urlString = "https://t.me/ikira18?text=\(encoded)"

        if let url = URL(string: urlString) {
            UIApplication.shared.open(url) { _ in
                isPresented = false
                appName = ""
                appLink = ""
                appFeatures = ""
            }
        }
    }
}
