import AppKit

/// Notification posted when a file should be opened in the editor.
extension Notification.Name {
    static let openFileInEditor = Notification.Name("DFOpenFileInEditor")
}

// MARK: - DFCodeEditor

/// A toggleable code inspector pane with syntax highlighting, file tabs, line numbers, and search.
final class DFCodeEditor: NSView {

    // MARK: - Tab Model

    private struct FileTab {
        let path: String
        var scrollPosition: NSPoint
        var name: String { (path as NSString).lastPathComponent }
    }

    // MARK: - Properties

    private var tabs: [FileTab] = []
    private var activeTabIndex: Int = -1

    // UI components
    private let headerBar = NSView()
    private let tabBar = NSView()
    private let tabStack = NSStackView()
    private let gutterView = LineNumberGutter()
    private let scrollView = NSScrollView()
    private let textView = NSTextView()
    private let searchBar = NSView()
    private let searchField = NSTextField()
    private let matchCountLabel = NSTextField(labelWithString: "")
    private var searchBarVisible = false
    private var searchBarHeightConstraint: NSLayoutConstraint!
    private var searchMatches: [NSRange] = []
    private var currentMatchIndex: Int = -1

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = Theme.bg.cgColor
        buildUI()

        NotificationCenter.default.addObserver(
            self, selector: #selector(handleOpenFile(_:)),
            name: .openFileInEditor, object: nil
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Build UI

    private func buildUI() {
        // Header bar
        headerBar.wantsLayer = true
        headerBar.layer?.backgroundColor = Theme.surface1.cgColor
        headerBar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(headerBar)

        let headerLabel = NSTextField(labelWithString: "INSPECTOR")
        headerLabel.font = Theme.mono(10, weight: .medium)
        headerLabel.textColor = Theme.text3
        headerLabel.translatesAutoresizingMaskIntoConstraints = false
        headerBar.addSubview(headerLabel)

        let closeBtn = NSButton(title: "\u{00D7}", target: self, action: #selector(closePaneClicked))
        closeBtn.isBordered = false
        closeBtn.font = Theme.mono(14, weight: .medium)
        closeBtn.contentTintColor = Theme.text3
        closeBtn.translatesAutoresizingMaskIntoConstraints = false
        headerBar.addSubview(closeBtn)

        let headerBorder = NSView()
        headerBorder.wantsLayer = true
        headerBorder.layer?.backgroundColor = Theme.surface3.cgColor
        headerBorder.translatesAutoresizingMaskIntoConstraints = false
        headerBar.addSubview(headerBorder)

        // Tab bar
        tabBar.wantsLayer = true
        tabBar.layer?.backgroundColor = Theme.surface1.cgColor
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(tabBar)

        tabStack.orientation = .horizontal
        tabStack.spacing = 0
        tabStack.alignment = .centerY
        tabStack.translatesAutoresizingMaskIntoConstraints = false
        tabBar.addSubview(tabStack)

        let tabBorder = NSView()
        tabBorder.wantsLayer = true
        tabBorder.layer?.backgroundColor = Theme.surface3.cgColor
        tabBorder.translatesAutoresizingMaskIntoConstraints = false
        tabBar.addSubview(tabBorder)

        // Search bar (initially hidden via height constraint)
        searchBar.wantsLayer = true
        searchBar.layer?.backgroundColor = Theme.surface2.cgColor
        searchBar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(searchBar)

        searchField.placeholderString = "Search..."
        searchField.font = Theme.mono(12)
        searchField.textColor = Theme.text1
        searchField.backgroundColor = Theme.surface1
        searchField.drawsBackground = true
        searchField.isBordered = true
        searchField.focusRingType = .none
        searchField.target = self
        searchField.action = #selector(searchTextChanged)
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchBar.addSubview(searchField)

        let prevBtn = NSButton(title: "\u{25B2}", target: self, action: #selector(searchPrev))
        prevBtn.isBordered = false
        prevBtn.font = Theme.mono(10)
        prevBtn.contentTintColor = Theme.text2
        prevBtn.translatesAutoresizingMaskIntoConstraints = false
        searchBar.addSubview(prevBtn)

        let nextBtn = NSButton(title: "\u{25BC}", target: self, action: #selector(searchNext))
        nextBtn.isBordered = false
        nextBtn.font = Theme.mono(10)
        nextBtn.contentTintColor = Theme.text2
        nextBtn.translatesAutoresizingMaskIntoConstraints = false
        searchBar.addSubview(nextBtn)

        matchCountLabel.font = Theme.mono(10)
        matchCountLabel.textColor = Theme.text3
        matchCountLabel.translatesAutoresizingMaskIntoConstraints = false
        searchBar.addSubview(matchCountLabel)

        let closeSearchBtn = NSButton(title: "\u{00D7}", target: self, action: #selector(hideSearch))
        closeSearchBtn.isBordered = false
        closeSearchBtn.font = Theme.mono(12, weight: .medium)
        closeSearchBtn.contentTintColor = Theme.text3
        closeSearchBtn.translatesAutoresizingMaskIntoConstraints = false
        searchBar.addSubview(closeSearchBtn)

        searchBarHeightConstraint = searchBar.heightAnchor.constraint(equalToConstant: 0)

        // Text scroll view + gutter
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = true
        scrollView.backgroundColor = Theme.bg
        scrollView.borderType = .noBorder
        scrollView.autohidesScrollers = true
        addSubview(scrollView)

        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = true
        textView.backgroundColor = Theme.bg
        textView.textColor = Theme.text1
        textView.font = Theme.mono(13)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 4, height: 4)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        scrollView.documentView = textView

        gutterView.translatesAutoresizingMaskIntoConstraints = false
        gutterView.textView = textView
        addSubview(gutterView)

        // Observe scroll changes for gutter sync
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(scrollViewDidScroll),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )

        // Also observe text storage changes for gutter
        NotificationCenter.default.addObserver(
            self, selector: #selector(textDidChange),
            name: NSText.didChangeNotification,
            object: textView
        )

        // Empty state label
        let emptyLabel = NSTextField(labelWithString: "No file open")
        emptyLabel.font = Theme.mono(12)
        emptyLabel.textColor = Theme.text3
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.tag = 999
        addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            // Header
            headerBar.topAnchor.constraint(equalTo: topAnchor),
            headerBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            headerBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            headerBar.heightAnchor.constraint(equalToConstant: 30),

            headerLabel.centerYAnchor.constraint(equalTo: headerBar.centerYAnchor),
            headerLabel.leadingAnchor.constraint(equalTo: headerBar.leadingAnchor, constant: 12),

            closeBtn.centerYAnchor.constraint(equalTo: headerBar.centerYAnchor),
            closeBtn.trailingAnchor.constraint(equalTo: headerBar.trailingAnchor, constant: -8),
            closeBtn.widthAnchor.constraint(equalToConstant: 20),

            headerBorder.bottomAnchor.constraint(equalTo: headerBar.bottomAnchor),
            headerBorder.leadingAnchor.constraint(equalTo: headerBar.leadingAnchor),
            headerBorder.trailingAnchor.constraint(equalTo: headerBar.trailingAnchor),
            headerBorder.heightAnchor.constraint(equalToConstant: 1),

            // Tab bar
            tabBar.topAnchor.constraint(equalTo: headerBar.bottomAnchor),
            tabBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            tabBar.heightAnchor.constraint(equalToConstant: 28),

            tabStack.leadingAnchor.constraint(equalTo: tabBar.leadingAnchor, constant: 4),
            tabStack.centerYAnchor.constraint(equalTo: tabBar.centerYAnchor),
            tabStack.trailingAnchor.constraint(lessThanOrEqualTo: tabBar.trailingAnchor, constant: -4),

            tabBorder.bottomAnchor.constraint(equalTo: tabBar.bottomAnchor),
            tabBorder.leadingAnchor.constraint(equalTo: tabBar.leadingAnchor),
            tabBorder.trailingAnchor.constraint(equalTo: tabBar.trailingAnchor),
            tabBorder.heightAnchor.constraint(equalToConstant: 1),

            // Search bar
            searchBar.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            searchBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            searchBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            searchBarHeightConstraint,

            searchField.leadingAnchor.constraint(equalTo: searchBar.leadingAnchor, constant: 8),
            searchField.centerYAnchor.constraint(equalTo: searchBar.centerYAnchor),
            searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),

            prevBtn.leadingAnchor.constraint(equalTo: searchField.trailingAnchor, constant: 4),
            prevBtn.centerYAnchor.constraint(equalTo: searchBar.centerYAnchor),
            prevBtn.widthAnchor.constraint(equalToConstant: 20),

            nextBtn.leadingAnchor.constraint(equalTo: prevBtn.trailingAnchor, constant: 2),
            nextBtn.centerYAnchor.constraint(equalTo: searchBar.centerYAnchor),
            nextBtn.widthAnchor.constraint(equalToConstant: 20),

            matchCountLabel.leadingAnchor.constraint(equalTo: nextBtn.trailingAnchor, constant: 6),
            matchCountLabel.centerYAnchor.constraint(equalTo: searchBar.centerYAnchor),

            closeSearchBtn.trailingAnchor.constraint(equalTo: searchBar.trailingAnchor, constant: -8),
            closeSearchBtn.centerYAnchor.constraint(equalTo: searchBar.centerYAnchor),
            closeSearchBtn.widthAnchor.constraint(equalToConstant: 20),

            // Gutter
            gutterView.topAnchor.constraint(equalTo: searchBar.bottomAnchor),
            gutterView.leadingAnchor.constraint(equalTo: leadingAnchor),
            gutterView.bottomAnchor.constraint(equalTo: bottomAnchor),
            gutterView.widthAnchor.constraint(equalToConstant: 44),

            // Scroll view
            scrollView.topAnchor.constraint(equalTo: searchBar.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: gutterView.trailingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            // Empty label
            emptyLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    // MARK: - Public API

    /// Open a file in the editor. Creates a new tab or switches to existing.
    func openFile(at path: String) {
        // Check if already open in a tab
        if let idx = tabs.firstIndex(where: { $0.path == path }) {
            switchToTab(idx)
            return
        }

        // Read file
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            // Try latin1 as fallback
            guard let content = try? String(contentsOfFile: path, encoding: .isoLatin1) else { return }
            let tab = FileTab(path: path, scrollPosition: .zero)
            tabs.append(tab)
            activeTabIndex = tabs.count - 1
            rebuildTabBar()
            displayContent(content, for: path)
            return
        }

        let tab = FileTab(path: path, scrollPosition: .zero)
        tabs.append(tab)
        activeTabIndex = tabs.count - 1
        rebuildTabBar()
        displayContent(content, for: path)
    }

    /// Toggle the search bar visibility.
    func toggleSearch() {
        if searchBarVisible {
            hideSearch()
        } else {
            showSearch()
        }
    }

    // MARK: - Notification Handlers

    @objc private func handleOpenFile(_ notification: Notification) {
        guard let path = notification.userInfo?["path"] as? String else { return }
        openFile(at: path)
    }

    // MARK: - Close Pane

    @objc private func closePaneClicked() {
        // Post notification to toggle editor visibility
        NotificationCenter.default.post(name: .toggleEditorPane, object: nil)
    }

    // MARK: - Tab Management

    private func switchToTab(_ index: Int) {
        guard index >= 0, index < tabs.count else { return }

        // Save scroll position for current tab
        if activeTabIndex >= 0, activeTabIndex < tabs.count {
            tabs[activeTabIndex].scrollPosition = scrollView.contentView.bounds.origin
        }

        activeTabIndex = index
        rebuildTabBar()

        // Load file content
        let tab = tabs[index]
        if let content = try? String(contentsOfFile: tab.path, encoding: .utf8) {
            displayContent(content, for: tab.path)
        } else if let content = try? String(contentsOfFile: tab.path, encoding: .isoLatin1) {
            displayContent(content, for: tab.path)
        }

        // Restore scroll position
        DispatchQueue.main.async { [weak self] in
            self?.scrollView.contentView.scroll(to: tab.scrollPosition)
            self?.scrollView.reflectScrolledClipView(self!.scrollView.contentView)
        }
    }

    @objc private func tabClicked(_ sender: NSButton) {
        switchToTab(sender.tag)
    }

    @objc private func closeTabClicked(_ sender: NSButton) {
        let index = sender.tag
        guard index >= 0, index < tabs.count else { return }

        tabs.remove(at: index)

        if tabs.isEmpty {
            activeTabIndex = -1
            textView.string = ""
            if let storage = textView.textStorage {
                storage.setAttributedString(NSAttributedString(string: ""))
            }
        } else if activeTabIndex >= tabs.count {
            activeTabIndex = tabs.count - 1
            switchToTab(activeTabIndex)
        } else if index <= activeTabIndex {
            activeTabIndex = max(0, activeTabIndex - 1)
            switchToTab(activeTabIndex)
        }

        rebuildTabBar()
        updateEmptyState()
        gutterView.needsDisplay = true
    }

    private func rebuildTabBar() {
        for v in tabStack.arrangedSubviews {
            tabStack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }

        for (i, tab) in tabs.enumerated() {
            let isActive = i == activeTabIndex

            let container = NSView()
            container.translatesAutoresizingMaskIntoConstraints = false
            container.wantsLayer = true
            container.layer?.cornerRadius = 3
            container.layer?.backgroundColor = isActive ? Theme.surface2.cgColor : NSColor.clear.cgColor

            let nameBtn = NSButton(title: "", target: self, action: #selector(tabClicked(_:)))
            nameBtn.tag = i
            nameBtn.translatesAutoresizingMaskIntoConstraints = false
            nameBtn.isBordered = false
            let attrs: [NSAttributedString.Key: Any] = [
                .font: Theme.mono(10, weight: isActive ? .medium : .regular),
                .foregroundColor: isActive ? Theme.text1 : Theme.text3,
            ]
            nameBtn.attributedTitle = NSAttributedString(string: " \(tab.name) ", attributes: attrs)
            container.addSubview(nameBtn)

            let closeBtn = NSButton(title: "\u{00D7}", target: self, action: #selector(closeTabClicked(_:)))
            closeBtn.tag = i
            closeBtn.translatesAutoresizingMaskIntoConstraints = false
            closeBtn.isBordered = false
            closeBtn.font = Theme.mono(9)
            closeBtn.contentTintColor = Theme.text3
            container.addSubview(closeBtn)

            NSLayoutConstraint.activate([
                container.heightAnchor.constraint(equalToConstant: 22),
                nameBtn.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                nameBtn.centerYAnchor.constraint(equalTo: container.centerYAnchor),
                closeBtn.leadingAnchor.constraint(equalTo: nameBtn.trailingAnchor, constant: -2),
                closeBtn.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -2),
                closeBtn.centerYAnchor.constraint(equalTo: container.centerYAnchor),
                closeBtn.widthAnchor.constraint(equalToConstant: 14),
            ])

            tabStack.addArrangedSubview(container)
        }

        updateEmptyState()
    }

    private func updateEmptyState() {
        let empty = tabs.isEmpty
        if let emptyLabel = viewWithTag(999) {
            emptyLabel.isHidden = !empty
        }
        scrollView.isHidden = empty
        gutterView.isHidden = empty
        tabBar.isHidden = empty
    }

    // MARK: - Content Display & Syntax Highlighting

    private func displayContent(_ content: String, for path: String) {
        let lang = detectLanguage(from: path)
        let highlighted = applySyntaxHighlighting(to: content, language: lang)

        textView.textStorage?.setAttributedString(highlighted)
        updateEmptyState()

        DispatchQueue.main.async { [weak self] in
            self?.gutterView.needsDisplay = true
        }
    }

    private func detectLanguage(from path: String) -> String {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "swift": return "swift"
        case "py": return "python"
        case "js": return "javascript"
        case "ts": return "typescript"
        case "rs": return "rust"
        case "go": return "go"
        case "rb": return "ruby"
        case "json": return "json"
        case "yaml", "yml": return "yaml"
        case "md": return "markdown"
        case "sh", "bash", "zsh": return "shell"
        case "c", "h": return "c"
        case "cpp", "cc", "cxx", "hpp": return "cpp"
        case "java": return "java"
        case "css": return "css"
        case "html", "htm": return "html"
        case "xml": return "xml"
        default: return "plain"
        }
    }

    private func applySyntaxHighlighting(to text: String, language: String) -> NSAttributedString {
        let baseAttrs: [NSAttributedString.Key: Any] = [
            .font: Theme.mono(13),
            .foregroundColor: Theme.text1,
        ]
        let result = NSMutableAttributedString(string: text, attributes: baseAttrs)
        let fullRange = NSRange(location: 0, length: (text as NSString).length)

        // Block comments: /* ... */
        applyPattern(#"/\*[\s\S]*?\*/"#, to: result, in: fullRange, color: Theme.text3, dotMatchesNewlines: true)

        // Line comments: // ...
        applyPattern(#"//[^\n]*"#, to: result, in: fullRange, color: Theme.text3)

        // Shell / Python / Ruby / YAML line comments: # ...
        if ["python", "ruby", "shell", "yaml"].contains(language) {
            applyPattern(#"#[^\n]*"#, to: result, in: fullRange, color: Theme.text3)
        }

        // Strings: double-quoted
        applyPattern(#""(?:[^"\\]|\\.)*""#, to: result, in: fullRange, color: Theme.green)

        // Strings: single-quoted
        applyPattern(#"'(?:[^'\\]|\\.)*'"#, to: result, in: fullRange, color: Theme.green)

        // Numbers: integer and float literals
        applyPattern(#"\b\d+\.?\d*(?:[eE][+-]?\d+)?\b"#, to: result, in: fullRange, color: Theme.yellow)

        // Keywords (language-aware)
        let keywords = keywordsFor(language: language)
        if !keywords.isEmpty {
            let kwPattern = "\\b(" + keywords.joined(separator: "|") + ")\\b"
            applyPattern(kwPattern, to: result, in: fullRange, color: Theme.accent)
        }

        // Types: capitalized words after certain tokens
        applyPattern(#"(?<=:\s?)\b[A-Z][A-Za-z0-9_]*\b"#, to: result, in: fullRange, color: Theme.cyan)
        applyPattern(#"(?<=\bas\s)\b[A-Z][A-Za-z0-9_]*\b"#, to: result, in: fullRange, color: Theme.cyan)
        applyPattern(#"(?<=class\s)\b[A-Z][A-Za-z0-9_]*\b"#, to: result, in: fullRange, color: Theme.cyan)
        applyPattern(#"(?<=struct\s)\b[A-Z][A-Za-z0-9_]*\b"#, to: result, in: fullRange, color: Theme.cyan)
        applyPattern(#"(?<=enum\s)\b[A-Z][A-Za-z0-9_]*\b"#, to: result, in: fullRange, color: Theme.cyan)
        applyPattern(#"(?<=protocol\s)\b[A-Z][A-Za-z0-9_]*\b"#, to: result, in: fullRange, color: Theme.cyan)

        return result
    }

    private func keywordsFor(language: String) -> [String] {
        switch language {
        case "swift":
            return ["func", "class", "struct", "enum", "let", "var", "if", "else", "for",
                    "while", "return", "import", "guard", "switch", "case", "break",
                    "continue", "protocol", "extension", "override", "private", "public",
                    "internal", "fileprivate", "open", "static", "self", "nil", "true",
                    "false", "init", "deinit", "throws", "throw", "try", "catch", "defer",
                    "where", "in", "is", "as", "typealias", "associatedtype", "weak",
                    "unowned", "lazy", "mutating", "final", "required", "convenience",
                    "dynamic", "optional", "some", "any", "async", "await"]
        case "python":
            return ["def", "class", "if", "elif", "else", "for", "while", "return",
                    "import", "from", "as", "with", "try", "except", "finally", "raise",
                    "pass", "break", "continue", "and", "or", "not", "in", "is", "None",
                    "True", "False", "lambda", "yield", "global", "nonlocal", "assert",
                    "del", "async", "await"]
        case "javascript", "typescript":
            return ["function", "class", "const", "let", "var", "if", "else", "for",
                    "while", "return", "import", "export", "from", "switch", "case",
                    "break", "continue", "new", "this", "null", "undefined", "true",
                    "false", "try", "catch", "finally", "throw", "async", "await",
                    "yield", "typeof", "instanceof", "delete", "void", "default",
                    "extends", "implements", "interface", "type", "enum", "static",
                    "private", "public", "protected", "readonly", "abstract"]
        case "rust":
            return ["fn", "struct", "enum", "let", "mut", "if", "else", "for", "while",
                    "loop", "return", "use", "mod", "pub", "crate", "self", "super",
                    "match", "impl", "trait", "type", "const", "static", "ref", "move",
                    "async", "await", "unsafe", "where", "true", "false", "as", "in",
                    "break", "continue", "extern", "dyn"]
        case "go":
            return ["func", "type", "struct", "interface", "var", "const", "if", "else",
                    "for", "range", "return", "import", "package", "switch", "case",
                    "break", "continue", "defer", "go", "select", "chan", "map", "nil",
                    "true", "false", "default", "fallthrough"]
        case "ruby":
            return ["def", "class", "module", "if", "elsif", "else", "unless", "for",
                    "while", "until", "return", "require", "include", "extend", "do",
                    "end", "begin", "rescue", "ensure", "raise", "yield", "block_given",
                    "self", "nil", "true", "false", "and", "or", "not", "in", "then",
                    "case", "when", "break", "next", "redo", "retry", "attr_reader",
                    "attr_writer", "attr_accessor", "puts", "print"]
        case "json":
            return ["true", "false", "null"]
        case "shell":
            return ["if", "then", "else", "elif", "fi", "for", "while", "do", "done",
                    "case", "esac", "function", "return", "exit", "echo", "export",
                    "local", "readonly", "shift", "set", "unset", "source", "in",
                    "true", "false"]
        default:
            return []
        }
    }

    private func applyPattern(_ pattern: String, to attrString: NSMutableAttributedString,
                              in range: NSRange, color: NSColor, dotMatchesNewlines: Bool = false) {
        var options: NSRegularExpression.Options = []
        if dotMatchesNewlines {
            options.insert(.dotMatchesLineSeparators)
        }
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return }
        let matches = regex.matches(in: attrString.string, options: [], range: range)
        for match in matches {
            attrString.addAttribute(.foregroundColor, value: color, range: match.range)
        }
    }

    // MARK: - Search

    @objc private func showSearch() {
        searchBarVisible = true
        searchBarHeightConstraint.constant = 30
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            self.searchBar.animator().alphaValue = 1
        }
        window?.makeFirstResponder(searchField)
    }

    @objc private func hideSearch() {
        searchBarVisible = false
        searchBarHeightConstraint.constant = 0
        searchField.stringValue = ""
        matchCountLabel.stringValue = ""
        clearSearchHighlights()
        searchMatches.removeAll()
        currentMatchIndex = -1
    }

    @objc private func searchTextChanged() {
        performSearch()
    }

    private func performSearch() {
        clearSearchHighlights()
        searchMatches.removeAll()
        currentMatchIndex = -1

        let query = searchField.stringValue
        guard !query.isEmpty else {
            matchCountLabel.stringValue = ""
            return
        }

        let text = textView.string as NSString
        var searchRange = NSRange(location: 0, length: text.length)

        while searchRange.location < text.length {
            let found = text.range(of: query as String,
                                    options: .caseInsensitive,
                                    range: searchRange)
            if found.location == NSNotFound { break }
            searchMatches.append(found)
            searchRange.location = found.location + found.length
            searchRange.length = text.length - searchRange.location
        }

        // Highlight all matches
        for match in searchMatches {
            textView.textStorage?.addAttribute(.backgroundColor,
                                               value: Theme.accent.withAlphaComponent(0.2),
                                               range: match)
        }

        if !searchMatches.isEmpty {
            currentMatchIndex = 0
            highlightCurrentMatch()
        }

        matchCountLabel.stringValue = searchMatches.isEmpty ? "No matches" : "\(currentMatchIndex + 1)/\(searchMatches.count)"
    }

    @objc private func searchPrev() {
        guard !searchMatches.isEmpty else { return }
        currentMatchIndex = (currentMatchIndex - 1 + searchMatches.count) % searchMatches.count
        highlightCurrentMatch()
        matchCountLabel.stringValue = "\(currentMatchIndex + 1)/\(searchMatches.count)"
    }

    @objc private func searchNext() {
        guard !searchMatches.isEmpty else { return }
        currentMatchIndex = (currentMatchIndex + 1) % searchMatches.count
        highlightCurrentMatch()
        matchCountLabel.stringValue = "\(currentMatchIndex + 1)/\(searchMatches.count)"
    }

    private func highlightCurrentMatch() {
        // Reset all to dim highlight
        for match in searchMatches {
            textView.textStorage?.addAttribute(.backgroundColor,
                                               value: Theme.accent.withAlphaComponent(0.2),
                                               range: match)
        }
        // Bright highlight on current
        guard currentMatchIndex >= 0, currentMatchIndex < searchMatches.count else { return }
        let current = searchMatches[currentMatchIndex]
        textView.textStorage?.addAttribute(.backgroundColor,
                                           value: Theme.accent.withAlphaComponent(0.5),
                                           range: current)
        textView.scrollRangeToVisible(current)
    }

    private func clearSearchHighlights() {
        guard let storage = textView.textStorage else { return }
        let fullRange = NSRange(location: 0, length: storage.length)
        storage.removeAttribute(.backgroundColor, range: fullRange)
    }

    // MARK: - Keyboard

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // Cmd+F: toggle search
        if flags == .command, event.keyCode == 3 { // 'f'
            toggleSearch()
            return
        }
        // Escape: close search
        if event.keyCode == 53, searchBarVisible {
            hideSearch()
            return
        }
        super.keyDown(with: event)
    }

    // MARK: - Gutter Sync

    @objc private func scrollViewDidScroll() {
        gutterView.needsDisplay = true
    }

    @objc private func textDidChange() {
        gutterView.needsDisplay = true
    }
}

// MARK: - Toggle notification

extension Notification.Name {
    static let toggleEditorPane = Notification.Name("DFToggleEditorPane")
}

// MARK: - Line Number Gutter

final class LineNumberGutter: NSView {
    weak var textView: NSTextView?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = Theme.surface1.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard let textView = textView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return }

        let text = textView.string as NSString
        guard text.length > 0 else { return }

        // Get visible rect in text view coordinates
        let visibleRect = textView.enclosingScrollView?.contentView.bounds ?? textView.visibleRect
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)
        let charRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)

        let attrs: [NSAttributedString.Key: Any] = [
            .font: Theme.mono(11),
            .foregroundColor: Theme.text3,
        ]

        // Walk through lines in visible range
        var lineNumber = 1
        // Count lines before visible range
        let beforeText = text.substring(to: charRange.location)
        lineNumber = beforeText.components(separatedBy: "\n").count

        var index = charRange.location
        while index < min(charRange.location + charRange.length, text.length) {
            let lineRange = text.lineRange(for: NSRange(location: index, length: 0))

            // Get the glyph rect for this line
            let glyphIdx = layoutManager.glyphIndexForCharacter(at: index)
            var lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIdx, effectiveRange: nil)

            // Convert from text view coordinates to gutter coordinates
            lineRect.origin.y += textView.textContainerInset.height
            lineRect.origin.y -= visibleRect.origin.y

            let numStr = "\(lineNumber)" as NSString
            let strSize = numStr.size(withAttributes: attrs)
            let drawPoint = NSPoint(
                x: bounds.width - strSize.width - 6,
                y: lineRect.origin.y + (lineRect.height - strSize.height) / 2
            )
            numStr.draw(at: drawPoint, withAttributes: attrs)

            lineNumber += 1
            index = lineRange.location + lineRange.length
            if index <= charRange.location { break } // prevent infinite loop
        }
    }
}

// MARK: - File Icon Helper

enum FileIcon {
    static func symbolName(for filename: String) -> String {
        let ext = (filename as NSString).pathExtension.lowercased()
        switch ext {
        case "swift", "py", "js", "ts", "rs", "go", "rb", "c", "cpp", "h", "hpp",
             "java", "cs", "php", "sh", "bash", "zsh", "pl", "r", "m", "mm":
            return "doc.text"
        case "json", "yaml", "yml", "toml", "ini", "cfg", "conf", "plist",
             "xcconfig", "gitignore", "env":
            return "gear"
        case "png", "jpg", "jpeg", "gif", "bmp", "tiff", "svg", "ico", "webp":
            return "photo"
        case "md", "txt", "rtf", "doc", "docx", "pdf":
            return "doc.plaintext"
        case "html", "htm", "css", "scss", "less", "xml":
            return "globe"
        default:
            return "doc"
        }
    }
}
