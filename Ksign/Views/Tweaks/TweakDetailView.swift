import SwiftUI
import NimbleViews

struct TweakDetailView: View {
    let item: TweakLibraryItem
    @ObservedObject var manager: TweakLibraryManager

    @Environment(\.dismiss) private var dismiss
    @State private var showExporter = false
    @State private var showDeleteAlert = false

    private var isAutoInjected: Binding<Bool> {
        Binding(
            get: { manager.isAutoInjected(item) },
            set: { manager.setAutoInject(item, enabled: $0) }
        )
    }

    var body: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    Image(systemName: item.kind.systemImage)
                        .font(.system(size: 32, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 58, height: 58)
                        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                    VStack(alignment: .leading, spacing: 5) {
                        Text(item.name)
                            .font(.headline)
                            .lineLimit(3)

                        Text(item.subtitle)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 6)
            }

            Section("Injection") {
                Toggle(isOn: isAutoInjected) {
                    Label("Inject Into Every App", systemImage: "syringe.fill")
                }

                Text("When enabled, this tweak is added automatically to the signing tweaks list. You can still turn it off from the signing screen before signing any app.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("File") {
                LabeledContent("Type", value: item.kind.title)
                LabeledContent("Size", value: item.formattedSize)
                LabeledContent("Location", value: item.url.lastPathComponent)

                if let date = item.modificationDate {
                    LabeledContent("Modified", value: date.formatted(date: .abbreviated, time: .shortened))
                }
            }

            Section {
                Button {
                    UIActivityViewController.show(activityItems: [item.url])
                } label: {
                    Label("Share", systemImage: "square.and.arrow.up")
                }

                Button {
                    showExporter = true
                } label: {
                    Label("Export to Files", systemImage: "folder.badge.plus")
                }

                Button(role: .destructive) {
                    showDeleteAlert = true
                } label: {
                    Label("Delete Tweak", systemImage: "trash")
                }
            }
        }
        .navigationTitle("Tweak Info")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showExporter) {
            FileExporterRepresentableView(
                urlsToExport: [item.url],
                asCopy: true,
                useLastLocation: false,
                onCompletion: { _ in showExporter = false }
            )
        }
        .alert("Delete Tweak?", isPresented: $showDeleteAlert) {
            Button("Delete", role: .destructive) {
                manager.delete(item)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the tweak from the Tweak Manager and from auto-inject settings.")
        }
    }
}
