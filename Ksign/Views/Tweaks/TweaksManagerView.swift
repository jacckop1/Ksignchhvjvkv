import SwiftUI
import UniformTypeIdentifiers
import NimbleViews

struct TweaksManagerView: View {
    @StateObject private var manager = TweakLibraryManager()

    @State private var searchText = ""
    @State private var sortOption: TweakSortOption = .name
    @State private var sortAscending = true
    @State private var selectedItems = Set<TweakLibraryItem>()
    @State private var isSelecting = false

    @State private var showImporter = false
    @State private var showIPAImporter = false
    @State private var showLibraryExtractor = false
    @State private var showExporter = false
    @State private var showDeleteAlert = false
    @State private var showURLPrompt = false
    @State private var urlText = ""
    @State private var autoInjectNewImports = false
    @State private var extractionSession: TweakExtractionSession?

    private var tweakImportTypes: [UTType] { UTType.tweakPickerFiles }
    private var ipaImportTypes: [UTType] { UTType.ipaFiles }

    private var visibleItems: [TweakLibraryItem] {
        manager.filteredItems(searchText: searchText, sortOption: sortOption, ascending: sortAscending)
    }

    private var selectedURLs: [URL] {
        selectedItems.map(\.url)
    }

    var body: some View {
        NavigationStack {
            List {
                if manager.isWorking {
                    Section {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 12) {
                                ProgressView()
                                Text(manager.downloadProgressText ?? "جارٍ المعالجة...")
                                    .foregroundStyle(.secondary)
                            }

                            if let progress = manager.downloadProgress {
                                ProgressView(value: progress)
                                    .progressViewStyle(.linear)

                                Text("\(Int((progress * 100).rounded()))%")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }

                if let message = manager.statusMessage, !message.isEmpty {
                    Section {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Toggle(isOn: $autoInjectNewImports) {
                        Label("Auto-inject new imports", systemImage: "syringe.fill")
                    }
                } footer: {
                    Text("When enabled, imported tweaks are added automatically to the signing tweaks list.")
                }

                Section("Tweak Manager", content: {
                    ForEach(visibleItems) { item in
                        row(for: item)
                    }
                })
            }
            .listStyle(.insetGrouped)
            .navigationTitle("TWEAKS")
            .searchable(text: $searchText, placement: .platform(), prompt: "Search tweaks")
            .overlay {
                if !manager.isWorking && manager.items.isEmpty {
                    emptyView
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if isSelecting {
                        Button("Done") {
                            isSelecting = false
                            selectedItems.removeAll()
                        }
                    }
                }

                ToolbarItemGroup(placement: .topBarTrailing) {
                    if isSelecting {
                        Menu {
                            Button {
                                setAutoInjectForSelection(true)
                            } label: {
                                Label("Auto Inject", systemImage: "syringe.fill")
                            }
                            .disabled(selectedItems.isEmpty)

                            Button {
                                setAutoInjectForSelection(false)
                            } label: {
                                Label("Remove Auto Inject", systemImage: "syringe")
                            }
                            .disabled(selectedItems.isEmpty)

                            Button {
                                UIActivityViewController.show(activityItems: selectedURLs)
                            } label: {
                                Label("Share", systemImage: "square.and.arrow.up")
                            }
                            .disabled(selectedItems.isEmpty)

                            Button {
                                showExporter = true
                            } label: {
                                Label("Export to Files", systemImage: "folder.badge.plus")
                            }
                            .disabled(selectedItems.isEmpty)

                            Button(role: .destructive) {
                                showDeleteAlert = true
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            .disabled(selectedItems.isEmpty)
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    } else {
                        Button {
                            isSelecting = true
                        } label: {
                            Image(systemName: "checklist")
                        }
                        .disabled(visibleItems.isEmpty)

                        sortMenu
                        importMenu
                    }
                }
            }
            .sheet(isPresented: $showImporter) {
                FileImporterRepresentableView(
                    allowedContentTypes: tweakImportTypes,
                    allowsMultipleSelection: true,
                    onDocumentsPicked: { urls in
                        showImporter = false
                        manager.importTweaks(from: urls, autoInject: autoInjectNewImports)
                    }
                )
            }
            .sheet(isPresented: $showIPAImporter) {
                FileImporterRepresentableView(
                    allowedContentTypes: ipaImportTypes,
                    allowsMultipleSelection: false,
                    onDocumentsPicked: { urls in
                        showIPAImporter = false
                        guard let url = urls.first else { return }
                        prepareExtraction(from: url)
                    }
                )
            }
            .sheet(isPresented: $showLibraryExtractor) {
                TweakLibraryAppPickerView { url in
                    prepareExtraction(from: url, delay: 0.35)
                }
            }
            .sheet(isPresented: $showExporter) {
                FileExporterRepresentableView(
                    urlsToExport: selectedURLs,
                    asCopy: true,
                    useLastLocation: false,
                    onCompletion: { _ in showExporter = false }
                )
            }
            .sheet(item: $extractionSession) { session in
                TweakExtractionSelectionView(
                    manager: manager,
                    session: session,
                    autoInjectNewImports: autoInjectNewImports
                )
            }
            .alert("استيراد من رابط", isPresented: $showURLPrompt) {
                TextField("https://example.com/tweak.deb أو app.ipa", text: $urlText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                Button("استيراد") {
                    let url = urlText
                    urlText = ""
                    Task {
                        if let session = await manager.downloadAndPrepareImport(
                            from: url,
                            autoInject: autoInjectNewImports
                        ) {
                            extractionSession = session
                        }
                    }
                }

                Button("إلغاء", role: .cancel) {
                    urlText = ""
                }
            } message: {
                Text("ألصق رابط مباشر لملف .dylib أو .deb أو .framework أو رابط IPA لاستخراج التويكات منه.")
            }
            .alert("Delete Tweaks?", isPresented: $showDeleteAlert) {
                Button("Delete", role: .destructive) {
                    manager.delete(Array(selectedItems))
                    selectedItems.removeAll()
                    isSelecting = false
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This permanently removes the selected tweaks and removes them from auto-inject settings.")
            }
            .onAppear {
                manager.load()
            }
        }
    }

    @ViewBuilder
    private func row(for item: TweakLibraryItem) -> some View {
        if isSelecting {
            TweakRowView(
                item: item,
                isSelected: selectedItems.contains(item),
                isAutoInjected: manager.isAutoInjected(item),
                isSelecting: true
            )
            .onTapGesture {
                toggleSelection(item)
            }
        } else {
            NavigationLink {
                TweakDetailView(item: item, manager: manager)
            } label: {
                TweakRowView(
                    item: item,
                    isSelected: false,
                    isAutoInjected: manager.isAutoInjected(item),
                    isSelecting: false
                )
            }
            .contextMenu {
                Button {
                    manager.setAutoInject(item, enabled: !manager.isAutoInjected(item))
                } label: {
                    Label(manager.isAutoInjected(item) ? "Remove Auto Inject" : "Auto Inject", systemImage: "syringe.fill")
                }

                Button {
                    UIActivityViewController.show(activityItems: [item.url])
                } label: {
                    Label("Share", systemImage: "square.and.arrow.up")
                }

                Button(role: .destructive) {
                    manager.delete(item)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }

    private var emptyView: some View {
        Group {
            if #available(iOS 17, *) {
                ContentUnavailableView {
                    Label("لا توجد تعديلات", systemImage: "wrench.and.screwdriver.fill")
                } description: {
                    Text("استورد .dylib أو .deb أو .framework، أو استخرج التعديلات من IPA.")
                } actions: {
                    Button {
                        showImporter = true
                    } label: {
                        Text("استيراد التعديلات").bg()
                    }
                }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "wrench.and.screwdriver.fill")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)

                    Text("لا توجد تعديلات")
                        .font(.headline)

                    Text("استورد .dylib أو .deb أو .framework، أو استخرج التعديلات من IPA.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)

                    Button("استيراد التعديلات") {
                        showImporter = true
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding()
            }
        }
    }

    private var importMenu: some View {
        Menu {
            Button {
                showImporter = true
            } label: {
                Label("استيراد من الملفات", systemImage: "doc.badge.plus")
            }

            Button {
                showURLPrompt = true
            } label: {
                Label("استيراد من رابط", systemImage: "link")
            }

            Button {
                showIPAImporter = true
            } label: {
                Label("استخراج من IPA", systemImage: "archivebox")
            }

            Button {
                showLibraryExtractor = true
            } label: {
                Label("استخراج من التوقيع", systemImage: "signature")
            }
        } label: {
            Image(systemName: "plus")
        }
    }

    private var sortMenu: some View {
        Menu {
            ForEach(TweakSortOption.allCases) { option in
                Button {
                    if sortOption == option {
                        sortAscending.toggle()
                    } else {
                        sortOption = option
                        sortAscending = true
                    }
                } label: {
                    HStack {
                        Text(option.title)
                        if sortOption == option {
                            Image(systemName: sortAscending ? "chevron.up" : "chevron.down")
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "line.3.horizontal.decrease")
        }
    }

    private func toggleSelection(_ item: TweakLibraryItem) {
        if selectedItems.contains(item) {
            selectedItems.remove(item)
        } else {
            selectedItems.insert(item)
        }
    }

    private func setAutoInjectForSelection(_ enabled: Bool) {
        for item in selectedItems {
            manager.setAutoInject(item, enabled: enabled)
        }
    }

    private func prepareExtraction(from url: URL, delay: TimeInterval = 0) {
        let run = {
            Task {
                if let session = await manager.prepareExtractionSession(from: url) {
                    extractionSession = session
                }
            }
        }

        if delay > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                run()
            }
        } else {
            run()
        }
    }
}
