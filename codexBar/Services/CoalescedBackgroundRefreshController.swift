import Foundation

@MainActor
final class CoalescedBackgroundRefreshController<Result> {
    typealias Loader = @Sendable (Date) -> Result
    typealias Deliver = @MainActor (Result) -> Void

    private struct PendingRequest {
        let now: Date
        let load: Loader
        let apply: Deliver
    }

    private let queue: DispatchQueue
    private var generation = 0
    private var isRefreshing = false
    private var pendingRequest: PendingRequest?

    init(queue: DispatchQueue = .global(qos: .utility)) {
        self.queue = queue
    }

    // Swift 6.3.3 的 EarlyPerfInliner 会在优化此泛型类型的合成析构函数时崩溃。
    // 显式保留一个无优化的空析构函数，避免影响其余 Release 代码的优化级别。
    @_optimize(none)
    deinit {}

    func requestRefresh(
        now: Date = Date(),
        load: @escaping Loader,
        apply: @escaping Deliver
    ) {
        let request = PendingRequest(now: now, load: load, apply: apply)
        if self.isRefreshing {
            self.pendingRequest = request
            return
        }

        self.start(request)
    }

    private func start(_ request: PendingRequest) {
        self.isRefreshing = true
        let generation = self.generation
        self.queue.async {
            let result = request.load(request.now)

            Task { @MainActor [weak self] in
                guard let self else { return }

                if generation == self.generation {
                    request.apply(result)
                }

                self.isRefreshing = false
                if let pendingRequest = self.pendingRequest {
                    self.pendingRequest = nil
                    self.start(pendingRequest)
                }
            }
        }
    }

    func reset() {
        self.generation += 1
        self.pendingRequest = nil
    }
}
