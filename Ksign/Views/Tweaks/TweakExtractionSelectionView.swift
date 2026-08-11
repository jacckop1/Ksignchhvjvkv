import SwiftUI

struct TweakExtractionSelectionView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var manager: TweakLibraryManager

    let session: TweakExtractionSession
    let autoInjectNewImports: Bool

    @State private var selectedIDs: Set<String> = []
    @State private var didSubmit = false

    private var selectedCandidates: [TweakExtractionCandidate] {
        session.candidates.filter { selectedIDs.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: "archivebox.fill")
                            .font(.title3)
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 34, height: 34)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(session.sourceName)
                                .font(.headline)
                                .lineLimit(2)

                            Text("تم العثور على \(session.candidates.count) ملف. حدد الذي تريد استخراجه فقط.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section("الملفات المستخرجة") {
                    ForEach(session.candidates) { candidate in
                        Button {
                            toggle(candidate)
                        } label: {
                            HStack(spacing: 12) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(Color.accentColor.opacity(0.13))
                                        .frame(width: 42, height: 42)

                                    Image(systemName: candidate.kind.systemImage)
                                        .font(.system(size: 18, weight: .semibold))
                                        .foregroundStyle(Color.accentColor)
                                }

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(candidate.name)
                                        .font(.body.weight(.semibold))
                                        .foregroundStyle(.primary)
                                        .lineLimit(2)

                                    Text(candidate.subtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }

                                Spacer(minLength: 8)

                                Image(systemName: selectedIDs.contains(candidate.id) ? "checkmark.circle.fill" : "circle")
                                    .font(.title3)
                                    .foregroundStyle(selectedIDs.contains(candidate.id) ? Color.accentColor : Color.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("اختيار التعديلات")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("إلغاء") {
                        didSubmit = true
                        manager.cleanupExtractionSession(session)
                        dismiss()
                    }
                }

                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button(selectedIDs.count == session.candidates.count ? "إلغاء تحديد الكل" : "تحديد الكل") {
                        if selectedIDs.count == session.candidates.count {
                            selectedIDs.removeAll()
                        } else {
                            selectedIDs = Set(session.candidates.map(\.id))
                        }
                    }

                    Button("استخراج") {
                        didSubmit = true
                        manager.importSelectedTweaks(
                            selectedCandidates,
                            from: session,
                            autoInject: autoInjectNewImports
                        )
                        dismiss()
                    }
                    .disabled(selectedIDs.isEmpty)
                }
            }
            .onAppear {
                selectedIDs = Set(session.candidates.map(\.id))
            }
            .onDisappear {
                if !didSubmit {
                    manager.cleanupExtractionSession(session)
                }
            }
        }
    }

    private func toggle(_ candidate: TweakExtractionCandidate) {
        if selectedIDs.contains(candidate.id) {
            selectedIDs.remove(candidate.id)
        } else {
            selectedIDs.insert(candidate.id)
        }
    }
}
