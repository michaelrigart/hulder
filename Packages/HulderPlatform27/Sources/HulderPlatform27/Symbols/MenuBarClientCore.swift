import Foundation
import HulderCore

/// Loads the private framework and looks classes up by name, so tests can inject a missing one.
struct ClassResolver: Sendable {
    let loadFramework: @Sendable (String) -> Bool
    let lookup: @Sendable (String) -> AnyClass?

    static let live = ClassResolver(
        loadFramework: { dlopen($0, RTLD_NOW) != nil },
        lookup: { NSClassFromString($0) }
    )

    static let frameworkMissing = ClassResolver(loadFramework: { _ in false }, lookup: { _ in nil })

    static func missing(_ classNames: [String]) -> ClassResolver {
        let names = Set(classNames)
        return ClassResolver(
            loadFramework: live.loadFramework,
            lookup: { names.contains($0) ? nil : live.lookup($0) }
        )
    }
}

/// The private MenuBarClientCore framework, resolved at run time. A missing class or selector
/// makes `availability` `.unavailable`; no call into the framework is made in that case.
struct MenuBarClientCore: Sendable {
    static let frameworkPath = "/System/Library/PrivateFrameworks/MenuBarClientCore.framework/MenuBarClientCore"
    static let frameworkName = "MenuBarClientCore"
    static let assertionClassName = "MBAssessmentModeAssertion"
    static let configurationClassName = "MBAssessmentModeConfiguration"

    private static let initConfigurationSelector = "initWithAllowedSystemItems:allowedBundleIdentifiers:"
    private static let activateSelector = "activateWithConfiguration:completionHandler:"
    private static let invalidateSelector = "invalidate"

    private typealias InitConfigurationFunction = @convention(c) (AnyObject, Selector, NSArray, NSArray) -> Unmanaged<AnyObject>?
    private typealias ActivateFunction = @convention(c) (AnyObject, Selector, AnyObject, @escaping @convention(block) (NSError?) -> Void) -> Void
    private typealias InvalidateFunction = @convention(c) (AnyObject, Selector) -> Void

    private struct Classes: Sendable {
        let assertion: NSObject.Type
        let configuration: NSObject.Type
    }

    private let classes: Classes?
    let availability: Availability

    init(resolver: ClassResolver = .live) {
        switch Self.resolve(resolver) {
        case .success(let classes):
            self.classes = classes
            availability = .available
        case .failure(let reason):
            classes = nil
            availability = .unavailable(reason.text)
        }
    }

    /// An allow-list configuration, or nil when the framework is unavailable.
    func makeConfiguration(systemItems: [Int], bundleIDs: [String]) -> NSObject? {
        guard let classes else { return nil }
        let selector = NSSelectorFromString(Self.initConfigurationSelector)
        guard let allocated = (classes.configuration as AnyObject).perform(NSSelectorFromString("alloc")),
              let imp = classes.configuration.instanceMethod(for: selector) else { return nil }
        let initialize = unsafeBitCast(imp, to: InitConfigurationFunction.self)
        // alloc returns +1 and the init family consumes it, so `allocated` is not released here.
        let result = initialize(
            allocated.takeUnretainedValue(),
            selector,
            systemItems.map { NSNumber(value: $0) } as NSArray,
            bundleIDs as NSArray
        )
        return result?.takeRetainedValue() as? NSObject
    }

    func makeAssertion() -> NSObject? {
        classes?.assertion.init()
    }

    /// Calls `activateWithConfiguration:completionHandler:`. The handler may run on any queue.
    func activate(_ assertion: NSObject, configuration: NSObject, completion: @escaping @Sendable (NSError?) -> Void) {
        let selector = NSSelectorFromString(Self.activateSelector)
        guard let imp = assertion.method(for: selector) else {
            completion(NSError(domain: "Hulder.MenuBarClientCore", code: 1))
            return
        }
        unsafeBitCast(imp, to: ActivateFunction.self)(assertion, selector, configuration) { completion($0) }
    }

    func invalidate(_ assertion: NSObject) {
        let selector = NSSelectorFromString(Self.invalidateSelector)
        guard let imp = assertion.method(for: selector) else { return }
        unsafeBitCast(imp, to: InvalidateFunction.self)(assertion, selector)
    }

    private struct Missing: Error { let text: String }

    private static func resolve(_ resolver: ClassResolver) -> Result<Classes, Missing> {
        guard resolver.loadFramework(frameworkPath) else { return .failure(Missing(text: "\(frameworkName) missing")) }
        guard let assertion = resolver.lookup(assertionClassName) as? NSObject.Type else {
            return .failure(Missing(text: "\(assertionClassName) missing"))
        }
        guard let configuration = resolver.lookup(configurationClassName) as? NSObject.Type else {
            return .failure(Missing(text: "\(configurationClassName) missing"))
        }
        let checks: [(NSObject.Type, String)] = [
            (configuration, initConfigurationSelector),
            (assertion, activateSelector),
            (assertion, invalidateSelector),
        ]
        for (type, name) in checks where !type.instancesRespond(to: NSSelectorFromString(name)) {
            return .failure(Missing(text: "\(name) missing"))
        }
        return .success(Classes(assertion: assertion, configuration: configuration))
    }
}
