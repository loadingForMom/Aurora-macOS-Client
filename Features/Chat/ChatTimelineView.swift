//
//  ChatTimelineView.swift
//  Aurora
//

import SwiftUI
import AppKit

@MainActor
struct ChatTimelineContainer: View {
    @ObservedObject var store: TelegramStore
    let chat: TGChat

    @StateObject private var viewModel: ChatTimelineViewModel

    @MainActor
    init(store: TelegramStore, chat: TGChat) {
        self.store = store
        self.chat = chat
        _viewModel = StateObject(wrappedValue: ChatTimelineViewModel(store: store, chat: chat, renderer: MessageTextRenderer()))
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            ChatTimelineRepresentable(viewModel: viewModel)

            if viewModel.newIncomingCount > 0 && !viewModel.isAtBottom {
                Button {
                    viewModel.scrollToBottom()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 12, weight: .semibold))
                        Text("\(viewModel.newIncomingCount) новых")
                            .font(.caption.weight(.semibold))
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 12)
                    .background(.regularMaterial, in: Capsule(style: .continuous))
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .padding(.trailing, 18)
                .padding(.bottom, 84)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .id(chat.id)
        .onChange(of: chat.id) { _ in
            viewModel.updateChat(chat)
        }
    }
}

struct ChatTimelineRepresentable: NSViewRepresentable {
    @ObservedObject var viewModel: ChatTimelineViewModel

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> ChatTimelineNSView {
        let view = ChatTimelineNSView()
        view.bind(viewModel)
        context.coordinator.boundViewModel = viewModel
        return view
    }

    func updateNSView(_ nsView: ChatTimelineNSView, context: Context) {
        if context.coordinator.boundViewModel !== viewModel {
            context.coordinator.boundViewModel = viewModel
            DispatchQueue.main.async {
                nsView.bind(viewModel)
            }
        }
    }

    final class Coordinator {
        var boundViewModel: ChatTimelineViewModel?
    }
}

final class ChatTimelineNSView: NSView {
    private enum Section {
        case main
    }

    private let scrollView = NSScrollView()
    private let documentContainer = NSView()
    private let collectionView = NSCollectionView()
    private var dataSource: NSCollectionViewDiffableDataSource<Section, ChatMessageItem>?

    private weak var viewModel: ChatTimelineViewModel?
    private var isBound = false

    private let bottomThreshold: CGFloat = 24

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    func bind(_ viewModel: ChatTimelineViewModel) {
        guard self.viewModel !== viewModel else { return }
        self.viewModel = viewModel
        viewModel.onWindowUpdate = { [weak self] update in
            DispatchQueue.main.async {
                self?.apply(update)
            }
        }
        DispatchQueue.main.async { [weak viewModel] in
            viewModel?.emitCurrentWindow()
        }
        isBound = true
    }

    private func setup() {
        wantsLayer = true

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.verticalScrollElasticity = .allowed
        scrollView.horizontalScrollElasticity = .none
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let layout = NSCollectionViewCompositionalLayout { _, _ in
            let itemSize = NSCollectionLayoutSize(
                widthDimension: .fractionalWidth(1.0),
                heightDimension: .estimated(48)
            )
            let item = NSCollectionLayoutItem(layoutSize: itemSize)

            let groupSize = NSCollectionLayoutSize(
                widthDimension: .fractionalWidth(1.0),
                heightDimension: .estimated(48)
            )
            let group = NSCollectionLayoutGroup.vertical(layoutSize: groupSize, subitems: [item])
            let section = NSCollectionLayoutSection(group: group)
            section.interGroupSpacing = 8
            section.contentInsets = NSDirectionalEdgeInsets(top: 14, leading: 0, bottom: 14, trailing: 0)
            return section
        }

        collectionView.collectionViewLayout = layout
        collectionView.isSelectable = false
        collectionView.backgroundColors = [.clear]
        collectionView.register(MessageCollectionViewItem.self, forItemWithIdentifier: MessageCollectionViewItem.identifier)
        collectionView.delegate = self
        collectionView.prefetchDataSource = self
        collectionView.translatesAutoresizingMaskIntoConstraints = false

        documentContainer.translatesAutoresizingMaskIntoConstraints = false
        documentContainer.addSubview(collectionView)

        scrollView.documentView = documentContainer
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            documentContainer.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            documentContainer.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            documentContainer.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            documentContainer.bottomAnchor.constraint(greaterThanOrEqualTo: scrollView.contentView.bottomAnchor),
            documentContainer.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),

            collectionView.leadingAnchor.constraint(equalTo: documentContainer.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: documentContainer.trailingAnchor),
            collectionView.topAnchor.constraint(equalTo: documentContainer.topAnchor),
            documentContainer.bottomAnchor.constraint(equalTo: collectionView.bottomAnchor)
        ])

        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScroll),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )

        let dataSource = NSCollectionViewDiffableDataSource<Section, ChatMessageItem>(collectionView: collectionView) { [weak self] collectionView, indexPath, item in
            guard let cell = collectionView.makeItem(withIdentifier: MessageCollectionViewItem.identifier, for: indexPath) as? MessageCollectionViewItem else {
                return nil
            }
            guard let viewModel = self?.viewModel, let message = viewModel.messageById(item) else { return cell }
            #if DEBUG
            assert(message.chatId == viewModel.chat.id, "Rendered message from wrong chat: \(message.chatId) != \(viewModel.chat.id)")
            #endif
            let senderName = self?.senderName(for: message)
            cell.representedObject = message
            cell.configure(with: message, senderName: senderName, renderer: viewModel.renderer)
            cell.onRetry = { [weak self] in
                self?.viewModel?.store.retrySend(message: message)
            }
            cell.onDelete = { [weak self] in
                self?.viewModel?.store.deleteMessages(chatId: message.chatId, messageIds: [message.id], revoke: true)
            }
            return cell
        }
        self.dataSource = dataSource
        collectionView.dataSource = dataSource
    }

    private func senderName(for message: TGMessage) -> String? {
        guard let viewModel else { return nil }
        guard viewModel.chat.kind.isGroup else { return nil }
        guard !message.isOutgoing else { return nil }
        return viewModel.store.userDisplayName(message.senderUserId)
    }

    private func apply(_ update: ChatTimelineViewModel.WindowUpdate) {
        #if DEBUG
        let uniqueCount = Set(update.items).count
        assert(uniqueCount == update.items.count, "Duplicate chat message identifiers in snapshot: \(update.items.count - uniqueCount)")
        #endif
        var snapshot = NSDiffableDataSourceSnapshot<Section, ChatMessageItem>()
        snapshot.appendSections([.main])
        snapshot.appendItems(update.items, toSection: .main)

        if !update.reloadIds.isEmpty {
            let reloadItems = update.items.filter { update.reloadIds.contains($0.messageId) }
            snapshot.reloadItems(reloadItems)
        }

        dataSource?.apply(snapshot, animatingDifferences: update.animated) { [weak self] in
            guard let command = update.scrollCommand else { return }
            self?.perform(command)
        }
    }

    private func perform(_ command: ChatTimelineViewModel.ScrollCommand) {
        switch command {
        case .toBottom(let animated):
            scrollToBottom(animated: animated)
        case .toMessage(let id, let position):
            scrollToMessage(id: id, position: position)
        }
    }

    private func scrollToBottom(animated: Bool) {
        guard let items = dataSource?.snapshot().itemIdentifiers, !items.isEmpty else { return }
        let index = items.count - 1
        let indexPath = IndexPath(item: index, section: 0)
        scrollToItem(indexPath, position: .bottom, animated: animated)
    }

    private func scrollToMessage(id: Int64, position: NSCollectionView.ScrollPosition) {
        guard let items = dataSource?.snapshot().itemIdentifiers else { return }
        guard let index = items.firstIndex(where: { $0.messageId == id }) else { return }
        scrollToItem(IndexPath(item: index, section: 0), position: position, animated: false)
    }

    private func scrollToItem(_ indexPath: IndexPath, position: NSCollectionView.ScrollPosition, animated: Bool) {
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                collectionView.animator().scrollToItems(at: [indexPath], scrollPosition: position)
            }
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                collectionView.scrollToItems(at: [indexPath], scrollPosition: position)
            }
        }
    }

    @objc private func handleScroll() {
        guard let viewModel else { return }
        let visible = collectionView.indexPathsForVisibleItems()
        let indices = visible.map { $0.item }
        let firstVisibleIndex = indices.min()
        let lastVisibleIndex = indices.max()

        let contentHeight = collectionView.collectionViewLayout?.collectionViewContentSize.height ?? collectionView.frame.height
        let offsetY = scrollView.contentView.bounds.origin.y
        let viewportHeight = scrollView.contentView.bounds.height
        let distanceToBottom = contentHeight - (offsetY + viewportHeight)
        let isAtBottom = distanceToBottom <= bottomThreshold

        #if DEBUG
        if let firstVisibleIndex, let lastVisibleIndex {
            print("ChatTimeline scroll chatId=\(viewModel.chat.id) first=\(firstVisibleIndex) last=\(lastVisibleIndex) offsetY=\(offsetY) viewport=\(viewportHeight) content=\(contentHeight) distance=\(distanceToBottom)")
        }
        #endif

        viewModel.handleScroll(firstVisibleIndex: firstVisibleIndex, lastVisibleIndex: lastVisibleIndex, isAtBottom: isAtBottom)
    }
}

extension ChatTimelineNSView: NSCollectionViewDelegate {
}

extension ChatTimelineNSView: NSCollectionViewPrefetching {
    func collectionView(_ collectionView: NSCollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
        let indices = indexPaths.map { $0.item }
        viewModel?.prefetch(indices: indices)
    }
}
