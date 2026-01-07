//
//  MessageCollectionViewItem.swift
//  Aurora
//

import AppKit

final class MessageCollectionViewItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("MessageCollectionViewItem")

    private let senderLabel = NSTextField(labelWithString: "")
    private let bubbleView = BubbleBackgroundView()
    private let textView = NSTextView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let stack = NSStackView()

    private var leadingConstraint: NSLayoutConstraint?
    private var trailingConstraint: NSLayoutConstraint?

    var onRetry: (() -> Void)?
    var onDelete: (() -> Void)?

    override func loadView() {
        view = NSView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.translatesAutoresizingMaskIntoConstraints = false

        senderLabel.font = .systemFont(ofSize: 11, weight: .medium)
        senderLabel.textColor = .secondaryLabelColor
        senderLabel.isHidden = true

        textView.drawsBackground = false
        textView.isEditable = false
        textView.isSelectable = true
        textView.textContainerInset = NSSize(width: 12, height: 8)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor

        bubbleView.translatesAutoresizingMaskIntoConstraints = false
        bubbleView.addSubview(textView)
        textView.translatesAutoresizingMaskIntoConstraints = false

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(senderLabel)
        stack.addArrangedSubview(bubbleView)
        stack.addArrangedSubview(statusLabel)

        view.addSubview(stack)

        leadingConstraint = stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18)
        trailingConstraint = stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -18)
        leadingConstraint?.isActive = true

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 2),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -2),

            bubbleView.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, multiplier: 0.72),

            textView.leadingAnchor.constraint(equalTo: bubbleView.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: bubbleView.trailingAnchor),
            textView.topAnchor.constraint(equalTo: bubbleView.topAnchor),
            textView.bottomAnchor.constraint(equalTo: bubbleView.bottomAnchor)
        ])
    }

    func configure(with message: TGMessage, senderName: String?, renderer: MessageTextRenderer) {
        senderLabel.stringValue = senderName ?? ""
        senderLabel.isHidden = senderName == nil

        let isOutgoing = message.isOutgoing
        bubbleView.isOutgoing = isOutgoing

        if isOutgoing {
            leadingConstraint?.isActive = false
            trailingConstraint?.isActive = true
            stack.alignment = .trailing
        } else {
            trailingConstraint?.isActive = false
            leadingConstraint?.isActive = true
            stack.alignment = .leading
        }

        let style = MessageTextStyle(fontSize: 14, isOutgoing: isOutgoing)
        renderer.render(message: message, style: style) { [weak self] attributed in
            self?.textView.textStorage?.setAttributedString(attributed)
        }

        statusLabel.attributedStringValue = statusAttributedString(for: message)

        onRetry = nil
        onDelete = nil
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let message = representedObject as? TGMessage else { return nil }
        guard message.isOutgoing else { return nil }

        let menu = NSMenu()
        if case .failed = message.sendState, message.canRetry {
            menu.addItem(withTitle: "Retry", action: #selector(handleRetry), keyEquivalent: "")
        }
        menu.addItem(withTitle: "Delete", action: #selector(handleDelete), keyEquivalent: "")
        return menu
    }

    @objc private func handleRetry() {
        onRetry?()
    }

    @objc private func handleDelete() {
        onDelete?()
    }

    private func statusAttributedString(for message: TGMessage) -> NSAttributedString {
        let attributed = NSMutableAttributedString()

        if message.isEdited {
            let edited = NSAttributedString(
                string: "edited ",
                attributes: [.foregroundColor: NSColor.secondaryLabelColor]
            )
            attributed.append(edited)
        }

        switch message.sendState {
        case .sent:
            let time = Self.relativeFormatter.localizedString(for: Date(timeIntervalSince1970: TimeInterval(message.date)), relativeTo: Date())
            attributed.append(NSAttributedString(string: time))

        case .pending:
            attributed.append(NSAttributedString(string: "Sending…"))

        case .failed:
            attributed.append(NSAttributedString(string: "Failed"))
        }

        return attributed
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()
}

private final class BubbleBackgroundView: NSView {
    var isOutgoing: Bool = false {
        didSet {
            updateAppearance()
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 16
        updateAppearance()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer?.cornerRadius = 16
        updateAppearance()
    }

    private func updateAppearance() {
        layer?.backgroundColor = (isOutgoing ? NSColor.systemBlue : NSColor.windowBackgroundColor.withAlphaComponent(0.9)).cgColor
        layer?.borderColor = NSColor.black.withAlphaComponent(0.06).cgColor
        layer?.borderWidth = 1
    }
}
