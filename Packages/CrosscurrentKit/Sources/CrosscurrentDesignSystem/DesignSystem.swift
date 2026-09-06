import CrosscurrentDomain
import AppKit
import SwiftUI

public enum CrosscurrentColor {
    public static let accent = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 1.0, green: 0.55, blue: 0.40, alpha: 1)
            : NSColor(srgbRed: 0.72, green: 0.22, blue: 0.12, alpha: 1)
    })
    public static let warmPaper = Color(red: 0.96, green: 0.94, blue: 0.90)
    public static let ink = Color(red: 0.12, green: 0.13, blue: 0.14)
    public static let muted = Color.secondary.opacity(0.72)
    public static let update = Color(nsColor: .systemBlue)
}

public struct StatusPill: View {
    public var text: String
    public var color: Color

    public init(_ text: String, color: Color = CrosscurrentColor.accent) { self.text = text; self.color = color }

    public var body: some View {
        Text(text.uppercased())
            .font(.caption2.weight(.bold))
            .tracking(0.8)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.10), in: Capsule())
    }
}

public struct SourceMonogram: View {
    public var name: String
    public var size: CGFloat

    public init(_ name: String, size: CGFloat = 28) { self.name = name; self.size = size }

    public var body: some View {
        Text(String(name.prefix(1)).uppercased())
            .font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
            .frame(width: size, height: size)
            .background(CrosscurrentColor.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: size * 0.3))
            .foregroundStyle(CrosscurrentColor.accent)
            .accessibilityHidden(true)
    }
}

public struct SectionRule: View {
    public var title: String
    public var trailing: String?

    public init(_ title: String, trailing: String? = nil) { self.title = title; self.trailing = trailing }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(LocalizedStringKey(title)).font(.title3.weight(.bold)).tracking(-0.25)
            Rectangle().frame(height: 1).foregroundStyle(.quaternary)
            if let trailing { Text(LocalizedStringKey(trailing)).font(.caption).foregroundStyle(.secondary) }
        }
    }
}

public struct EventReadMarker: View {
    public var status: RevisionReadStatus
    public init(_ status: RevisionReadStatus) { self.status = status }
    public var body: some View {
        Group {
            switch status {
            case .unread: Circle().fill(CrosscurrentColor.accent).frame(width: 6, height: 6)
            case .updated: Image(systemName: "arrow.clockwise").font(.system(size: 10, weight: .semibold)).foregroundStyle(CrosscurrentColor.update)
            case .read: Color.clear
            }
        }
        .frame(width: 12, height: 12)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .help(label)
    }

    private var label: LocalizedStringKey {
        switch status {
        case .unread: "Unread"
        case .updated: "Updated"
        case .read: "Already read"
        }
    }
}
