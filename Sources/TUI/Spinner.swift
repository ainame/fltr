import Foundation

/// A terminal spinner widget for loading animations.
///
/// Provides an animated spinner with various styles, inspired by fzf/skim.
/// The spinner cycles through frames to create an animation effect.
public struct Spinner: Sendable {
    /// Spinner style
    public enum Style: Sendable, Equatable {
        /// Braille dots spinner (default, compact)
        case braille
        /// Simple dots spinner
        case dots
        /// Arrow spinner
        case arrow
    }

    private let style: Style
    private let frames: [String]

    /// Initialize a spinner with the specified style.
    ///
    /// - Parameter style: The spinner style (default: .braille)
    public init(style: Style = .braille) {
        self.style = style
        self.frames = Self.framesForStyle(style)
    }

    /// Get the current frame for the given frame number.
    ///
    /// - Parameter frameNumber: The current frame number (auto-wrapping)
    /// - Returns: The spinner frame string
    public func frame(at frameNumber: Int) -> String {
        return frames[frameNumber % frames.count]
    }

    /// Total number of frames in this spinner's animation.
    public var frameCount: Int {
        return frames.count
    }

    private static func framesForStyle(_ style: Style) -> [String] {
        switch style {
        case .braille:
            return ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
        case .dots:
            return ["⠁", "⠂", "⠄", "⡀", "⢀", "⠠", "⠐", "⠈"]
        case .arrow:
            return ["←", "↖", "↑", "↗", "→", "↘", "↓", "↙"]
        }
    }
}
