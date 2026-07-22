import SwiftUI
import BackgroundTasks
import UserNotifications

@main
struct DutyPingApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = Store()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
        }
        .onChange(of: scenePhase) { phase in
            // Topping up on every foreground is what keeps the rolling horizon
            // from running out.
            if phase == .active { store.commit() }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    private static let refreshTaskID = "com.dutyping.app.refresh"

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        Scheduler.shared.registerCategories()

        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.refreshTaskID, using: nil) { task in
            self.handleRefresh(task: task)
        }
        scheduleRefresh()
        return true
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        scheduleRefresh()
    }

    // MARK: - Background top-up

    private func scheduleRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: Self.refreshTaskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 12 * 60 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    private func handleRefresh(task: BGTask) {
        scheduleRefresh()

        let work = Task {
            let store = await Store()
            let shifts = await store.shifts
            let settings = await store.settings
            await Scheduler.shared.rescheduleAsync(shifts: shifts, settings: settings)
            task.setTaskCompleted(success: true)
        }
        task.expirationHandler = { work.cancel() }
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async
                                -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        Scheduler.shared.handle(response: response)
    }
}
