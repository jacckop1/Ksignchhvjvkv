//
//  Storage+Sources.swift
//  Feather
//
//  Created by samara on 12.04.2025.
//

import CoreData
import AltSourceKit

// MARK: - Display Model (UI Safe)
struct SourceDisplay {
    let name: String
    let iconURL: URL?
    let identifier: String
}

// MARK: - Class extension: Sources
extension Storage {

    /// ⚠️ Raw data (internal use only)
    func getSources() -> [AltSource] {
        let request: NSFetchRequest<AltSource> = AltSource.fetchRequest()
        return (try? context.fetch(request)) ?? []
    }

    /// ✅ UI SAFE: use this instead of getSources() in SwiftUI
    func getDisplaySources() -> [SourceDisplay] {
        let sources = getSources()

        return sources.map {
            SourceDisplay(
                name: $0.name ?? "Unknown Source",
                iconURL: $0.iconURL,
                identifier: $0.identifier ?? ""
            )
        }
    }

    func addSource(
        _ url: URL,
        name: String? = "Unknown",
        identifier: String,
        iconURL: URL? = nil,
        deferSave: Bool = false,
        isBuiltIn: Bool = false,
        completion: @escaping (Error?) -> Void
    ) {
        if sourceExists(identifier) {
            completion(nil)
            print("ignoring \(identifier)")
            return
        }

        let new = AltSource(context: context)
        new.name = name
        new.date = Date()
        new.identifier = identifier

        // 🔐 URL محفوظ داخليًا فقط (لا يُعرض في UI)
        new.sourceURL = url

        new.iconURL = iconURL
        new.setValue(isBuiltIn, forKey: "isBuiltIn")

        do {
            if !deferSave {
                try context.save()
            }
            completion(nil)
        } catch {
            completion(error)
        }
    }

    func addSource(
        _ url: URL,
        repository: ASRepository,
        id: String = "",
        deferSave: Bool = false,
        isBuiltIn: Bool = false,
        completion: @escaping (Error?) -> Void
    ) {
        addSource(
            url,
            name: repository.name,
            identifier: !id.isEmpty
                ? id
                : (repository.id ?? url.absoluteString),
            iconURL: repository.currentIconURL,
            deferSave: deferSave,
            isBuiltIn: isBuiltIn,
            completion: completion
        )
    }

    func addSources(
        repos: [URL: ASRepository],
        completion: @escaping (Error?) -> Void
    ) {
        for (url, repo) in repos {
            addSource(
                url,
                repository: repo,
                deferSave: true,
                completion: { error in
                    if let error {
                        completion(error)
                    }
                }
            )
        }

        saveContext()
        completion(nil)
    }

    func initializeBuiltInSourcesIfNeeded() {
        let key = "ksign.safeBuiltInSources.v1"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        addBuiltInSources()
    }

    func addBuiltInSources() {
        let builtInSourceURLs = [
            "https://raw.githubusercontent.com/jacckop/source/main/ipastore",
            "https://raw.githubusercontent.com/jacckop/source/main/AppTesters",
            "https://fastsign.dev/repo.lite.json",
            "https://fastsign.dev/repo.json",
            "https://raw.githubusercontent.com/jacckop/source/main/iraq",
            "https://raw.githubusercontent.com/jacckop/source/main/mthk",
            "https://repository.apptesters.org",
            "https://ipa.cypwn.xyz/cypwn.json",
            "https://source.ryuksign.com",
            "https://raw.githubusercontent.com/jacckop/source/main/multi",
            "https://raw.githubusercontent.com/jacckop/source/main/develek",
            "https://raw.githubusercontent.com/jacckop/source/main/sidelix",
            "https://raw.githubusercontent.com/jacckop/source/main/resource/sorse_part1.json",
            "https://raw.githubusercontent.com/jacckop/source/main/resource/sorse_part2.json",
            "https://raw.githubusercontent.com/jacckop/source/main/resource/sorse_part3.json",
            "https://raw.githubusercontent.com/jacckop/source/main/resource/sorse_part4.json",
            "https://raw.githubusercontent.com/jacckop/source/main/resource/sorse_part5.json",
        ]

        // Stagger startup requests so the app is fully presented before network
        // callbacks arrive. Built-in imports must stay silent: duplicates or one
        // unavailable repository should never present an alert during launch.
        for (index, urlString) in builtInSourceURLs.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8 + (Double(index) * 0.12)) {
                FR.handleSource(urlString, showAlerts: false) { }
            }
        }
    }

    func deleteSource(for source: AltSource) {
        context.delete(source)
        saveContext()
    }

    func sourceExists(_ identifier: String) -> Bool {
        let fetchRequest: NSFetchRequest<AltSource> = AltSource.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "identifier == %@", identifier)

        do {
            let count = try context.count(for: fetchRequest)
            return count > 0
        } catch {
            print("Error checking if repository exists: \(error)")
            return false
        }
    }
}
