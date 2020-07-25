//
//  TimelineModel.swift
//  NetNewsWire
//
//  Created by Maurice Parker on 6/30/20.
//  Copyright © 2020 Ranchero Software. All rights reserved.
//

#if os(macOS)
import AppKit
#else
import UIKit
#endif
import Combine
import RSCore
import Account
import Articles

protocol TimelineModelDelegate: class {
	var selectedFeedsPublisher: AnyPublisher<[Feed], Never>? { get }
	func timelineRequestedWebFeedSelection(_: TimelineModel, webFeed: WebFeed)
}

class TimelineModel: ObservableObject, UndoableCommandRunner {
	
	weak var delegate: TimelineModelDelegate?
	
	@Published var nameForDisplay = ""
	@Published var selectedTimelineItemIDs = Set<String>()  // Don't use directly.  Use selectedTimelineItemsPublisher
	@Published var selectedTimelineItemID: String? = nil    // Don't use directly.  Use selectedTimelineItemsPublisher
	@Published var isReadFiltered: Bool? = nil

	var timelineItemsPublisher: AnyPublisher<TimelineItems, Never>?
	var articlesPublisher: AnyPublisher<[Article], Never>?
	var selectedTimelineItemsPublisher: AnyPublisher<[TimelineItem], Never>?
	var selectedArticlesPublisher: AnyPublisher<[Article], Never>?
	var articleStatusChangePublisher: AnyPublisher<Set<String>, Never>?
	
	var toggleReadStatusForSelectedArticlesSubject = PassthroughSubject<Void, Never>()
	
	
	var readFilterEnabledTable = [FeedIdentifier: Bool]()

	var undoManager: UndoManager?
	var undoableCommands = [UndoableCommand]()

	private var cancellables = Set<AnyCancellable>()

	private var sortDirectionSubject = ReplaySubject<Bool, Never>(bufferSize: 1)
	private var groupByFeedSubject = ReplaySubject<Bool, Never>(bufferSize: 1)

	private var timelineItems = TimelineItems()
	
	init(delegate: TimelineModelDelegate) {
		self.delegate = delegate
		subscribeToUserDefaultsChanges()
		subscribeToReadFilterChanges()
		subscribeToArticleFetchChanges()
		subscribeToSelectedArticleSelectionChanges()
		subscribeToArticleStatusChanges()
//		subscribeToAccountDidDownloadArticles()
		subscribeToArticleMarkingEvents()
	}
	
	// MARK: API
	
	func toggleReadFilter() {
//		guard let filter = isReadFiltered, let feedID = feeds.first?.feedID else { return }
//		readFilterEnabledTable[feedID] = !filter
//		isReadFiltered = !filter
//		self.fetchArticles()
	}

	@discardableResult
	func goToNextUnread() -> Bool {
//		var startIndex: Int
//		if let firstArticle = selectedArticles.first, let index = timelineItems.firstIndex(where: { $0.article == firstArticle }) {
//			startIndex = index
//		} else {
//			startIndex = 0
//		}
//
//		for i in startIndex..<timelineItems.count {
//			if !timelineItems[i].article.status.read {
//				select(timelineItems[i].article.articleID)
//				return true
//			}
//		}
//
		return false
	}

	func articleFor(_ articleID: String) -> Article? {
		return timelineItems[articleID]?.article
	}

	func findPrevArticle(_ article: Article) -> Article? {
		return nil
//		guard let index = articles.firstIndex(of: article), index > 0 else {
//			return nil
//		}
//		return articles[index - 1]
	}
	
	func findNextArticle(_ article: Article) -> Article? {
		return nil
//		guard let index = articles.firstIndex(of: article), index + 1 != articles.count else {
//			return nil
//		}
//		return articles[index + 1]
	}
	
	func selectArticle(_ article: Article) {
		// TODO: Implement me!
	}
	
}

// MARK: Private

private extension TimelineModel {
	
	// MARK: Subscriptions
	
	func subscribeToArticleStatusChanges() {
		articleStatusChangePublisher = NotificationCenter.default.publisher(for: .StatusesDidChange)
			.compactMap { $0.userInfo?[Account.UserInfoKey.articleIDs] as? Set<String> }
			.eraseToAnyPublisher()
	}
	
//	func subscribeToAccountDidDownloadArticles() {
//		NotificationCenter.default.publisher(for: .AccountDidDownloadArticles).sink { [weak self] note in
//			guard let self = self, let feeds = note.userInfo?[Account.UserInfoKey.webFeeds] as? Set<WebFeed> else {
//				return
//			}
//			if self.anySelectedFeedIntersection(with: feeds) || self.anySelectedFeedIsPseudoFeed() {
//				self.queueFetchAndMergeArticles()
//			}
//		}.store(in: &cancellables)
//	}
	
	// TODO: Don't forget to redo this!!!
	func subscribeToReadFilterChanges() {
		guard let selectedFeedsPublisher = delegate?.selectedFeedsPublisher else { return }

		selectedFeedsPublisher.sink { [weak self] feeds in
			guard let self = self else { return }
			
			guard feeds.count == 1, let timelineFeed = feeds.first else {
				self.isReadFiltered = nil
				return
			}
	
			guard timelineFeed.defaultReadFilterType != .alwaysRead else {
				self.isReadFiltered = nil
				return
			}
	
			if let feedID = timelineFeed.feedID, let readFilterEnabled = self.readFilterEnabledTable[feedID] {
				self.isReadFiltered =  readFilterEnabled
			} else {
				self.isReadFiltered = timelineFeed.defaultReadFilterType == .read
			}
		}
		.store(in: &cancellables)
	}
	
	func subscribeToUserDefaultsChanges() {
		let kickStartNote = Notification(name: Notification.Name("Kick Start"))
		NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
			.prepend(kickStartNote)
			.sink { [weak self] _ in
				self?.sortDirectionSubject.send(AppDefaults.shared.timelineSortDirection)
				self?.groupByFeedSubject.send(AppDefaults.shared.timelineGroupByFeed)
		}.store(in: &cancellables)
	}
	
	func subscribeToArticleFetchChanges() {
		guard let selectedFeedsPublisher = delegate?.selectedFeedsPublisher else { return }
		let sortDirectionPublisher = sortDirectionSubject.removeDuplicates()
		let groupByPublisher = groupByFeedSubject.removeDuplicates()
		
		timelineItemsPublisher = selectedFeedsPublisher
			.map { [weak self] feeds -> Set<Article> in
				return self?.fetchArticles(feeds: feeds) ?? Set<Article>()
			}
			.combineLatest(sortDirectionPublisher, groupByPublisher)
			.compactMap { [weak self] articles, sortDirection, groupBy in
				let sortedArticles = Array(articles).sortedByDate(sortDirection ? .orderedDescending : .orderedAscending, groupByFeed: groupBy)
				return self?.buildTimelineItems(articles: sortedArticles) ?? TimelineItems()
			}
			.share(replay: 1)
			.eraseToAnyPublisher()

		timelineItemsPublisher!
			.sink { [weak self] timelineItems in
				self?.timelineItems = timelineItems
			}
			.store(in: &cancellables)
		
		// Transform to articles for those that just need articles
		articlesPublisher = timelineItemsPublisher!
			.map { timelineItems in
				timelineItems.items.map { $0.article }
			}
			.share()
			.eraseToAnyPublisher()
		
		// Set the timeline name for display
		selectedFeedsPublisher
			.map { feeds -> String in
				switch feeds.count {
				case 0:
					return ""
				case 1:
					return feeds.first!.nameForDisplay
				default:
					return NSLocalizedString("Multiple", comment: "Multiple")
				}
			}
			.assign(to: &$nameForDisplay)
	}
	
	func subscribeToSelectedArticleSelectionChanges() {
		guard let timelineItemsPublisher = timelineItemsPublisher else { return }
		
		let timelineSelectedIDsPublisher = $selectedTimelineItemIDs
			.withLatestFrom(timelineItemsPublisher, resultSelector: { timelineItemIds, timelineItems -> [TimelineItem] in
				return timelineItemIds.compactMap { timelineItems[$0] }
			})
		
		let timelineSelectedIDPublisher = $selectedTimelineItemID
			.withLatestFrom(timelineItemsPublisher, resultSelector: { timelineItemId, timelineItems -> [TimelineItem] in
				if let id = timelineItemId, let item = timelineItems[id] {
					return [item]
				} else {
					return [TimelineItem]()
				}
			})
		
		selectedTimelineItemsPublisher = timelineSelectedIDsPublisher
			.merge(with: timelineSelectedIDPublisher)
			.share(replay: 1)
			.eraseToAnyPublisher()
		
		selectedArticlesPublisher = selectedTimelineItemsPublisher!
			.map { timelineItems in timelineItems.map { $0.article } }
			.share(replay: 1)
			.eraseToAnyPublisher()

		// Automatically mark a selected record as read
		selectedTimelineItemsPublisher!
			.filter { $0.count == 1 }
			.compactMap { $0.first?.article }
			.filter { !$0.status.read }
			.sink {	markArticles(Set([$0]), statusKey: .read, flag: true) }
			.store(in: &cancellables)
	}

	func subscribeToArticleMarkingEvents() {
		guard let selectedArticlesPublisher = selectedArticlesPublisher else { return }
		
		let toggleReadPublisher = toggleReadStatusForSelectedArticlesSubject
			.withLatestFrom(selectedArticlesPublisher)
			.filter { !$0.isEmpty }
			.map {selectedArticles -> ([Article], ArticleStatus.Key, Bool) in
				if selectedArticles.anyArticleIsUnread() {
					return (selectedArticles, ArticleStatus.Key.read, true)
				} else {
					return (selectedArticles, ArticleStatus.Key.read, false)
				}
			}
		
		toggleReadPublisher
			.sink { [weak self] (articles, key, flag) in
				if let undoManager = self?.undoManager,
				   let markReadCommand = MarkStatusCommand(initialArticles: articles, statusKey: key, flag: flag, undoManager: undoManager) {
					self?.runCommand(markReadCommand)
				} else {
					markArticles(Set(articles), statusKey: key, flag: flag)
				}
			}
			.store(in: &cancellables)
		
	}
	
	// MARK: Timeline Management

	func sortParametersDidChange() {
//		performBlockAndRestoreSelection {
//			articles = articles.sortedByDate(sortDirection ? .orderedDescending : .orderedAscending, groupByFeed: groupByFeed)
//			rebuildTimelineItems()
//		}
	}
	
	func performBlockAndRestoreSelection(_ block: (() -> Void)) {
//		let savedArticleIDs = selectedArticleIDs
//		let savedArticleID = selectedArticleID
		block()
//		selectedArticleIDs = savedArticleIDs
//		selectedArticleID = savedArticleID
	}
	
	// MARK: Article Fetching
	
	func fetchArticles(feeds: [Feed]) -> Set<Article> {
		if feeds.isEmpty {
			return Set<Article>()
		}

		var fetchedArticles = Set<Article>()
		for feed in feeds {
			if isReadFiltered ?? true {
				if let articles = try? feed.fetchUnreadArticles() {
					fetchedArticles.formUnion(articles)
				}
			} else {
				if let articles = try? feed.fetchArticles() {
					fetchedArticles.formUnion(articles)
				}
			}
		}

		return fetchedArticles
	}	
	
	func buildTimelineItems(articles: [Article]) -> TimelineItems {
		var items = TimelineItems()
		for (position, article) in articles.enumerated() {
			items.append(TimelineItem(position: position, article: article))
		}
		return items
	}

//	func anySelectedFeedIsPseudoFeed() -> Bool {
//		return feeds.contains(where: { $0 is PseudoFeed})
//	}
//
//	func anySelectedFeedIntersection(with webFeeds: Set<WebFeed>) -> Bool {
//		for feed in feeds {
//			if let selectedWebFeed = feed as? WebFeed {
//				for webFeed in webFeeds {
//					if selectedWebFeed.webFeedID == webFeed.webFeedID || selectedWebFeed.url == webFeed.url {
//						return true
//					}
//				}
//			} else if let folder = feed as? Folder {
//				for webFeed in webFeeds {
//					if folder.hasWebFeed(with: webFeed.webFeedID) || folder.hasWebFeed(withURL: webFeed.url) {
//						return true
//					}
//				}
//			}
//		}
//		return false
//	}
}
