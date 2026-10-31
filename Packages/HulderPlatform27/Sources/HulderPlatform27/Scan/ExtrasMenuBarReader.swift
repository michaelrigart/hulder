import ApplicationServices
import CoreGraphics
import Darwin

struct RawItem: Equatable, Sendable {
    let identifier: String?
    let description: String?
    let title: String?
    let frame: CGRect?
    let index: Int
}

enum RawScan: Equatable, Sendable {
    case items([RawItem])
    case timedOut
    case failed(AXError)
}

/// What one read of a process produced, with the live elements the items came from.
/// The elements are not `Sendable`: use them on the queue that produced them.
struct ExtrasInspection {
    let scan: RawScan
    let menuBar: AXUIElement?
    let itemElements: [AXUIElement]
}

/// Reads a process's status items through `kAXExtrasMenuBarAttribute`. Calls block, so run
/// them on an `AXQueue`.
enum ExtrasMenuBarReader {
    // The SDK declares no constant for "AXFrame".
    private static let frameAttribute = "AXFrame"

    static func runningPIDs() -> [pid_t] {
        let size = proc_listallpids(nil, 0)
        guard size > 0 else { return [] }
        // The list can grow between the two calls, so leave room for new processes.
        var pids = [pid_t](repeating: 0, count: Int(size) + 64)
        let bytes = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.stride))
        guard bytes > 0 else { return [] }
        return pids.prefix(Int(bytes) / MemoryLayout<pid_t>.stride).filter { $0 > 0 }
    }

    static func readItems(pid: pid_t, timeout: Float) -> RawScan {
        inspect(pid: pid, timeout: timeout).scan
    }

    static func inspect(pid: pid_t, timeout: Float) -> ExtrasInspection {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, timeout)

        let bar: AXUIElement
        switch copyValue(app, kAXExtrasMenuBarAttribute) {
        case .failed(let error):
            return ExtrasInspection(scan: scan(for: error), menuBar: nil, itemElements: [])
        case .value(let value):
            guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
                return ExtrasInspection(scan: .items([]), menuBar: nil, itemElements: [])
            }
            bar = unsafeDowncast(value, to: AXUIElement.self)
        }
        AXUIElementSetMessagingTimeout(bar, timeout)

        let children: [AXUIElement]
        switch copyValue(bar, kAXChildrenAttribute) {
        case .failed(let error):
            return ExtrasInspection(scan: scan(for: error), menuBar: bar, itemElements: [])
        case .value(let value):
            children = (value as? [AXUIElement]) ?? []
        }

        var items: [RawItem] = []
        for (index, element) in children.enumerated() {
            AXUIElementSetMessagingTimeout(element, timeout)
            var cannotComplete = false
            func string(_ attribute: String) -> String? {
                switch copyValue(element, attribute) {
                case .value(let value): return value as? String
                case .failed(let error):
                    cannotComplete = cannotComplete || error == .cannotComplete
                    return nil
                }
            }
            let identifier = string(kAXIdentifierAttribute)
            let description = string(kAXDescriptionAttribute)
            let title = string(kAXTitleAttribute)
            let frame = frame(of: element)
            if cannotComplete {
                return ExtrasInspection(scan: .timedOut, menuBar: bar, itemElements: [])
            }
            items.append(RawItem(identifier: identifier, description: description, title: title, frame: frame, index: index))
        }
        return ExtrasInspection(scan: .items(items), menuBar: bar, itemElements: children)
    }

    private static func scan(for error: AXError) -> RawScan {
        error == .cannotComplete ? .timedOut : .failed(error)
    }

    private enum Attribute {
        /// `nil` means the attribute is absent (no value, or unsupported).
        case value(CFTypeRef?)
        case failed(AXError)
    }

    private static func copyValue(_ element: AXUIElement, _ attribute: String) -> Attribute {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        switch error {
        case .success: return .value(value)
        case .noValue, .attributeUnsupported: return .value(nil)
        default: return .failed(error)
        }
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        guard case .value(let value?) = copyValue(element, frameAttribute),
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(unsafeDowncast(value, to: AXValue.self), .cgRect, &rect) else { return nil }
        return rect
    }
}
