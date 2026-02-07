import Foundation

/// A piece of declarative terminal UI
public protocol TUIView: Sendable {
    /// Render this view to a buffer string with ANSI codes
    func render(in context: RenderContext) -> String
}

/// Context passed during rendering
public struct RenderContext: Sendable {
    public let startRow: Int
    public let startCol: Int
    public let maxWidth: Int
    public let maxHeight: Int

    public init(startRow: Int, startCol: Int, maxWidth: Int, maxHeight: Int) {
        self.startRow = startRow
        self.startCol = startCol
        self.maxWidth = maxWidth
        self.maxHeight = maxHeight
    }
}

// MARK: - Basic Views

/// A text label
public struct Text: TUIView {
    private let content: String
    private var color: String = ""
    private var isBold: Bool = false

    public init(_ content: String) {
        self.content = content
    }

    public func render(in context: RenderContext) -> String {
        var output = ANSIColors.moveCursor(row: context.startRow, col: context.startCol)

        if isBold {
            output += ANSIColors.bold
        }
        if !color.isEmpty {
            output += color
        }

        let truncated = TextRenderer.truncate(content, width: context.maxWidth)
        output += truncated

        if !color.isEmpty || isBold {
            output += ANSIColors.reset
        }

        return output
    }

    public func foregroundColor(_ color: String) -> Text {
        var copy = self
        copy.color = color
        return copy
    }

    public func bold() -> Text {
        var copy = self
        copy.isBold = true
        return copy
    }
}

/// An animated spinner view
public struct SpinnerView: TUIView {
    private let style: Spinner.Style
    private let frame: Int

    public init(style: Spinner.Style = .braille, frame: Int) {
        self.style = style
        self.frame = frame
    }

    public func render(in context: RenderContext) -> String {
        let spinner = Spinner(style: style)
        var output = ANSIColors.moveCursor(row: context.startRow, col: context.startCol)
        output += spinner.frame(at: frame)
        return output
    }
}

/// A horizontal line separator
public struct Divider: TUIView {
    private let style: HorizontalSeparator.Style

    public init(style: HorizontalSeparator.Style = .light) {
        self.style = style
    }

    public func render(in context: RenderContext) -> String {
        let separator = HorizontalSeparator(style: style)
        return separator.render(row: context.startRow, width: context.maxWidth)
    }
}

/// Empty space
public struct Spacer: TUIView {
    public init() {}

    public func render(in context: RenderContext) -> String {
        return ""
    }
}

// MARK: - Layout Containers

/// Vertical stack - renders children top to bottom
public struct VStack: TUIView {
    private let spacing: Int
    private let children: [any TUIView]

    public init(spacing: Int = 1, @TUIViewBuilder content: () -> [any TUIView]) {
        self.spacing = spacing
        self.children = content()
    }

    public func render(in context: RenderContext) -> String {
        var output = ""
        var currentRow = context.startRow

        for child in children {
            let childContext = RenderContext(
                startRow: currentRow,
                startCol: context.startCol,
                maxWidth: context.maxWidth,
                maxHeight: context.maxHeight
            )
            output += child.render(in: childContext)
            currentRow += spacing
        }

        return output
    }
}

/// Horizontal stack - renders children left to right
public struct HStack: TUIView {
    private let spacing: Int
    private let children: [any TUIView]

    public init(spacing: Int = 2, @TUIViewBuilder content: () -> [any TUIView]) {
        self.spacing = spacing
        self.children = content()
    }

    public func render(in context: RenderContext) -> String {
        var output = ""
        var currentCol = context.startCol

        for child in children {
            let childContext = RenderContext(
                startRow: context.startRow,
                startCol: currentCol,
                maxWidth: context.maxWidth - (currentCol - context.startCol),
                maxHeight: context.maxHeight
            )
            output += child.render(in: childContext)
            // Approximate width - in real implementation we'd measure rendered output
            currentCol += spacing + 10  // Simplified
        }

        return output
    }
}

// MARK: - Result Builder

@resultBuilder
public struct TUIViewBuilder {
    public static func buildBlock(_ components: (any TUIView)...) -> [any TUIView] {
        components
    }

    public static func buildOptional(_ component: [any TUIView]?) -> [any TUIView] {
        component ?? []
    }

    public static func buildEither(first component: [any TUIView]) -> [any TUIView] {
        component
    }

    public static func buildEither(second component: [any TUIView]) -> [any TUIView] {
        component
    }

    public static func buildArray(_ components: [[any TUIView]]) -> [any TUIView] {
        components.flatMap { $0 }
    }
}
