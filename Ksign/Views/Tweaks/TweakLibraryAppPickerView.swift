import SwiftUI
import CoreData

struct TweakLibraryAppPickerView: View {
    @Environment(\.dismiss) private var dismiss

    let onPick: (URL) -> Void

    @State private var selectedTab = 0
    @State private var searchText = ""

    @FetchRequest(
        entity: Imported.entity(),
        sortDescriptors: [NSSortDescriptor(keyPath: \Imported.date, ascending: false)],
        animation: .snappy
    ) private var importedApps: FetchedResults<Imported>

    @FetchRequest(
        entity: Signed.entity(),
        sortDescriptors: [NSSortDescriptor(keyPath: \Signed.date, ascending: false)],
        animation: .snappy
    ) private var signedApps: FetchedResults<Signed>

    private var downloadedItems: [TweakLibraryAppSource] {
        makeItems(from: importedApps, kindTitle: "Downloaded")
    }

    private var signedItems: [TweakLibraryAppSource] {
        makeItems(from: signedApps, kindTitle: "Signed")
    }

    private var visibleItems: [TweakLibraryAppSource] {
        let base = selectedTab == 0 ? downloadedItems : signedItems
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return base }

        return base.filter { item in
            item.name.localizedCaseInsensitiveContains(query) ||
            item.bundleID.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $selectedTab) {
                    Text("التطبيقات المحملة").tag(0)
                    Text("التطبيقات الموقعة").tag(1)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 8)

                List {
                    Section(selectedTab == 0 ? "التطبيقات المحملة" : "التطبيقات الموقعة") {
                        ForEach(visibleItems) { item in
                            Button {
                                select(item)
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: item.systemImage)
                                        .font(.title3)
                                        .frame(width: 28)

                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(item.name)
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)

                                        Text(item.subtitle)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }

                                    Spacer()

                                    Image(systemName: "chevron.right")
                                        .font(.caption.weight(.bold))
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                }
                .overlay {
                    if visibleItems.isEmpty {
                        if #available(iOS 17, *) {
                            ContentUnavailableView {
                                Label("لا توجد تطبيقات", systemImage: "signature")
                            } description: {
                                Text("لا يوجد IPA قابل للاستخراج في هذا القسم من التوقيع.")
                            }
                        } else {
                            Text("لا يوجد IPA قابل للاستخراج في هذا القسم من التوقيع.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .padding()
                        }
                    }
                }
            }
            .navigationTitle("استخراج من التوقيع")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, placement: .platform(), prompt: "بحث في التوقيع")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("إغلاق") {
                        dismiss()
                    }
                }
            }
        }
    }

    private func makeItems<T: AppInfoPresentable>(from apps: FetchedResults<T>, kindTitle: String) -> [TweakLibraryAppSource] where T: NSManagedObject {
        apps.compactMap { app in
            guard let url = Storage.shared.getIPAPath(for: app) else { return nil }
            return TweakLibraryAppSource(
                id: app.uuid ?? url.path,
                name: app.name ?? "Unknown",
                bundleID: app.identifier ?? "",
                version: app.version ?? "",
                kindTitle: kindTitle,
                url: url,
                isSigned: app.isSigned
            )
        }
    }

    private func select(_ item: TweakLibraryAppSource) {
        dismiss()
        onPick(item.url)
    }
}

struct TweakLibraryAppSource: Identifiable, Hashable {
    let id: String
    let name: String
    let bundleID: String
    let version: String
    let kindTitle: String
    let url: URL
    let isSigned: Bool

    var systemImage: String {
        isSigned ? "checkmark.seal.fill" : "app.fill"
    }

    var subtitle: String {
        let cleanBundle = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanVersion = version.trimmingCharacters(in: .whitespacesAndNewlines)

        if !cleanBundle.isEmpty && !cleanVersion.isEmpty {
            return "\(cleanBundle) • v\(cleanVersion)"
        }

        if !cleanBundle.isEmpty {
            return cleanBundle
        }

        if !cleanVersion.isEmpty {
            return "v\(cleanVersion)"
        }

        return kindTitle
    }
}
