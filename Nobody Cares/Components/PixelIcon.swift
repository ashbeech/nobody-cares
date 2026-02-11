//
//  PixelIcon.swift
//  Nobody Cares
//
//  Icon system — SF Symbol placeholders with 1-bit pixel styling.
//  TODO: Replace with custom 16×16 / 24×24 pixel art assets.
//

import SwiftUI

enum PixelIconType: String {
    case eye            // Feed tab
    case camera         // Create tab (simple camera)
    case cameraPlus     // Create tab (camera with +)
    case gear           // Settings
    case flag           // Report
    case trash          // Delete
    case xmark          // Close
    case speaker        // Unmuted
    case speakerSlash   // Muted
    case block          // Block user
    case share          // Share / export
    case hourglass      // Loading
    case caution        // Warning / alert
    case lock           // Access denied
    case recycle        // Refresh / recycle

    /// SF Symbol name (placeholder until custom pixel art is bundled)
    var symbolName: String {
        switch self {
        case .eye:           return "eye"
        case .camera:        return "camera"
        case .cameraPlus:    return "camera.badge.plus"
        case .gear:          return "gearshape"
        case .flag:          return "flag"
        case .trash:         return "trash"
        case .xmark:         return "xmark"
        case .speaker:       return "speaker.wave.2"
        case .speakerSlash:  return "speaker.slash"
        case .block:         return "nosign"
        case .share:         return "square.and.arrow.up"
        case .hourglass:     return "hourglass"
        case .caution:       return "exclamationmark.triangle"
        case .lock:          return "lock"
        case .recycle:       return "arrow.2.circlepath"
        }
    }
}

struct PixelIcon: View {
    let type: PixelIconType
    var size: CGFloat = NCMetrics.iconSize
    var color: Color = NCColor.ink
    /// When true, icon uses filled variant (active state)
    var filled: Bool = false

    var body: some View {
        Image(systemName: filled ? filledSymbolName : type.symbolName)
            .font(.system(size: size * 0.65, weight: .bold))
            .foregroundColor(color)
            .frame(width: size, height: size)
    }

    private var filledSymbolName: String {
        switch type {
        case .eye:          return "eye.fill"
        case .camera:       return "camera.fill"
        case .cameraPlus:   return "camera.fill.badge.plus"
        case .gear:         return "gearshape.fill"
        case .flag:         return "flag.fill"
        case .trash:        return "trash.fill"
        case .speaker:      return "speaker.wave.2.fill"
        case .speakerSlash: return "speaker.slash.fill"
        case .caution:      return "exclamationmark.triangle.fill"
        case .lock:         return "lock.fill"
        default:            return type.symbolName
        }
    }
}

#Preview("Pixel Icons") {
    LazyVGrid(columns: [
        GridItem(.adaptive(minimum: 50))
    ], spacing: 16) {
        ForEach([
            PixelIconType.eye, .cameraPlus, .gear, .flag,
            .trash, .xmark, .speaker, .speakerSlash,
            .block, .share, .hourglass, .caution
        ], id: \.rawValue) { icon in
            VStack(spacing: 4) {
                PixelIcon(type: icon)
                Text(icon.rawValue)
                    .font(NCFont.caption)
            }
        }
    }
    .padding()
}
