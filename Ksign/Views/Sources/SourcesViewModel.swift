//
//  SourcesViewModel.swift
//  Feather
//
//  Created by samara on 30.04.2025.
//
import Foundation
import AltSourceKit
import SwiftUI
import NimbleJSON

// MARK: - Class
final class SourcesViewModel: ObservableObject, @unchecked Sendable {
	static let shared = SourcesViewModel()
	
	typealias RepositoryDataHandler = Result<ASRepository, Error>
	
	private let _dataService = NBFetchService()
	
	var isFinished = true
	@Published var sources: [AltSource: ASRepository] = [:]
	
	func fetchSources(_ sources: FetchedResults<AltSource>, refresh: Bool = false, batchSize: Int = 4) async {
		guard isFinished else { return }
		
		if !refresh, sources.allSatisfy({ self.sources[$0] != nil }) { return }
		
		isFinished = false
		defer { isFinished = true }
		
		await MainActor.run {
			self.sources = [:]
		}
		
		let sourcesArray = Array(sources)
		let sourceURLs: [(ObjectIdentifier, URL?)] = sourcesArray.map { (ObjectIdentifier($0), $0.sourceURL) }
		
		for startIndex in stride(from: 0, to: sourcesArray.count, by: batchSize) {
			let endIndex = min(startIndex + batchSize, sourcesArray.count)
			let batch = Array(sourcesArray[startIndex..<endIndex])
			let batchURLs = Array(sourceURLs[startIndex..<endIndex])
			
			let batchResults: [(Int, ASRepository?)] = await withTaskGroup(of: (Int, ASRepository?).self, returning: [(Int, ASRepository?)].self) { group in
				for (idx, (_, url)) in batchURLs.enumerated() {
					let absoluteIndex = startIndex + idx
					group.addTask { [weak self] in
						guard let self, let url else {
							return (absoluteIndex, nil)
						}
						return await withCheckedContinuation { continuation in
							self._dataService.fetch(from: url) { (result: RepositoryDataHandler) in
								switch result {
								case .success(let repo):
									continuation.resume(returning: (absoluteIndex, repo))
								case .failure:
									continuation.resume(returning: (absoluteIndex, nil))
								}
							}
						}
					}
				}
				
				var results = [(Int, ASRepository?)]()
				for await pair in group {
					results.append(pair)
				}
				return results
			}
			
			await MainActor.run {
				for (idx, repo) in batchResults {
					if let repo {
						self.sources[sourcesArray[idx]] = repo
					}
				}
			}
		}
	}
}
