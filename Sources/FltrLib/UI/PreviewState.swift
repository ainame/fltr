/// All preview-related view state in one place.
///
/// Owned as a single `var` on UIController.  Because it is a plain struct
/// stored on an actor, every read and write is already actor-isolated — no
/// extra synchronisation is needed.
///
/// Task lifecycle (`currentPreviewTask`) and the async helpers that spawn
/// those tasks (`refreshPreview`, `updatePreviewAsync`) deliberately stay
/// on UIController; only the *state* and the *pure render helpers* live here.
struct PreviewState {
    // ── configuration (immutable after init) ──────────────────────────────

    let command:     String?
    let useFloating: Bool
    let manager:     PreviewManager?

    // ── mutable view state ─────────────────────────────────────────────

    /// Last preview output; avoids re-running the command on every render.
    var cachedPreview:  String        = ""
    /// Scroll position inside the preview pane.
    var scrollOffset:   Int           = 0
    /// Floating-window visible? (only meaningful when useFloating == true)
    var showFloating:   Bool          = false
    /// Split-pane visible? (only meaningful when useFloating == false)
    var showSplit:      Bool
    /// Bounds for mouse hit-testing (1-indexed, inclusive).  Rewritten every
    /// frame by the render helpers below.
    var bounds:         PreviewBounds? = nil

    // ── derived ────────────────────────────────────────────────────────

    /// Whether any preview feature is configured at all.
    var isEnabled: Bool { command != nil }

    // ── init ───────────────────────────────────────────────────────────

    init(command: String?, useFloating: Bool) {
        self.command     = command
        self.useFloating = useFloating
        self.manager     = command != nil
            ? PreviewManager(command: command, useFloatingPreview: useFloating)
            : nil
        // Preview starts hidden; Ctrl-O is the opt-in toggle to show it.
        self.showSplit   = false
    }

    // ── state helpers ──────────────────────────────────────────────────

    /// Update the cached preview text.  Resets scroll to the top whenever
    /// the content actually changes (i.e. a different item was selected).
    mutating func setCached(_ preview: String) {
        if preview != cachedPreview {
            scrollOffset = 0
        }
        cachedPreview = preview
    }

    // ── render helpers ─────────────────────────────────────────────────
    // These read only PreviewState's own fields and forward to PreviewManager.
    // They are called from UIController.render() which assembles the full frame.

    /// Render the split-screen preview pane and update `bounds` for hit-testing.
    mutating func renderSplit(startRow: Int, endRow: Int, startCol: Int, width: Int, cols: Int) -> String {
        guard let manager = manager else { return "" }
        bounds = PreviewBounds(startRow: startRow, endRow: endRow, startCol: startCol, endCol: cols)
        return manager.renderSplitPreview(
            content:      cachedPreview,
            scrollOffset: scrollOffset,
            startRow:     startRow,
            endRow:       endRow,
            startCol:     startCol,
            width:        width
        )
    }

    /// Render the floating preview window and update `bounds`.
    /// `itemName` is the title text — derived by the caller from the
    /// current selection so that PreviewState stays free of matching state.
    mutating func renderFloating(rows: Int, cols: Int, itemName: String) -> String {
        guard showFloating, let manager = manager else {
            bounds = nil
            return ""
        }
        let (newBounds, buffer) = manager.renderFloatingPreview(
            content:      cachedPreview,
            scrollOffset: scrollOffset,
            itemName:     itemName,
            rows:         rows,
            cols:         cols
        )
        bounds = newBounds
        return buffer
    }
}
