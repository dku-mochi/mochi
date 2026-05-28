import Dependencies

public enum CalendarSyncerKey: DependencyKey {
    public static let liveValue: any CalendarSyncing = LiveCalendarSyncer()
    public static let testValue: any CalendarSyncing = UnconfiguredCalendarSyncer()
}

public extension DependencyValues {
    var calendarSyncer: any CalendarSyncing {
        get { self[CalendarSyncerKey.self] }
        set { self[CalendarSyncerKey.self] = newValue }
    }
}
