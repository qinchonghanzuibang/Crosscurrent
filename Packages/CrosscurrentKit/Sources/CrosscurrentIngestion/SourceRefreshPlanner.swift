import CrosscurrentDomain
import CrosscurrentStorage
import Foundation

public enum SourceRefreshPlanner {
    /// Selects due logical subscriptions; durable jobs retain retry and lease state.
    /// WeChat mirrors share one refresh so acquisition can choose a healthy endpoint.
    public static func dueEndpoints(in snapshots: [StoredSourceSnapshot], now: Date = .now) -> [SourceEndpoint] {
        snapshots.filter { !$0.source.isArchived }.flatMap { snapshot in
            let weChat = snapshot.endpoints.filter { $0.connector == .weChatOfficialAccount && $0.health != .disabled }
            let primary = weChat.min {
                let left = $0.weChatAcquisition?.priority ?? 100
                let right = $1.weChatAcquisition?.priority ?? 100
                return left == right ? $0.id.description < $1.id.description : left < right
            }
            let endpoints = snapshot.endpoints.filter { $0.connector != .weChatOfficialAccount } + [primary].compactMap { $0 }
            return endpoints.filter { endpoint in
                let isWeChat = endpoint.connector == .weChatOfficialAccount
                let interval: TimeInterval = isWeChat ? 4 * 60 * 60 : 30 * 60
                let lastSuccess = isWeChat ? weChat.compactMap(\.lastSuccessfulSync).max() : endpoint.lastSuccessfulSync
                let requiresUserAction: Set<ConnectorHealth> = [.authenticationRequired, .platformChanged, .configurationRequired, .disabled]
                return (isWeChat || !requiresUserAction.contains(endpoint.health))
                    && (lastSuccess.map { now.timeIntervalSince($0) >= interval } ?? true)
            }
        }
    }
}
