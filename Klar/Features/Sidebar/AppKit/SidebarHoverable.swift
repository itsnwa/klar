import AppKit

/// Cells implement this so the table/outline view can drive hover state from
/// a single tracking area at the container level (eliminating stuck-hover
/// bugs caused by per-row tracking-area fragility on scroll/recycle).
protocol SidebarHoverable: AnyObject {
    func setHovered(_ hovered: Bool)
}
