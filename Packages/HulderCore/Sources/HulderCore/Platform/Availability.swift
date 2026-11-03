public enum Availability: Equatable, Sendable {
    case available
    case unavailable(String)

    /// The reason a capability has before the platform first reports it.
    public static let notCheckedText = "Not checked yet."
    public static let notChecked = Availability.unavailable(notCheckedText)
}
