import WebKit

/// Keeps the theme pages off the network. They are local files and MenuBuddy promises to send
/// nothing anywhere, so a content rule list blocks every load that isn't file:, data:, blob: or
/// about: (images, scripts, styles, fonts, fetch, beacons, frames and navigations alike) before
/// WebKit sends it. Web views wait for the list (it compiles in a few milliseconds, once per launch)
/// and load nothing if it can't be compiled.
enum WebGuard {
    private static let rules = """
    [
      {"trigger": {"url-filter": ".*"}, "action": {"type": "block"}},
      {"trigger": {"url-filter": "^file:"}, "action": {"type": "ignore-previous-rules"}},
      {"trigger": {"url-filter": "^data:"}, "action": {"type": "ignore-previous-rules"}},
      {"trigger": {"url-filter": "^blob:"}, "action": {"type": "ignore-previous-rules"}},
      {"trigger": {"url-filter": "^about:"}, "action": {"type": "ignore-previous-rules"}}
    ]
    """
    // (WebKit's rule patterns have no "|", hence one rule per scheme.)
    private enum State { case idle, compiling, ready(WKContentRuleList), failed }
    private static var state = State.idle
    private static var waiting: [(WKContentRuleList) -> Void] = []

    /// Adds the rule list to `controller`, then runs `load` (on the main thread). Never runs `load`
    /// if the list failed to compile.
    static func protect(_ controller: WKUserContentController, then load: @escaping () -> Void) {
        withRules { list in
            controller.add(list)
            load()
        }
    }

    private static func withRules(_ body: @escaping (WKContentRuleList) -> Void) {
        switch state {
        case .ready(let list): body(list); return
        case .failed: return
        case .compiling: waiting.append(body); return
        case .idle: waiting.append(body)
        }
        state = .compiling
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "MenuBuddyOffline",
                                                                encodedContentRuleList: rules) { list, error in
            DispatchQueue.main.async {
                let callbacks = waiting
                waiting = []
                guard let list else {
                    NSLog("MenuBuddy: couldn't compile the offline rules, not loading theme pages: \(error?.localizedDescription ?? "?")")
                    state = .failed
                    return
                }
                state = .ready(list)
                callbacks.forEach { $0(list) }
            }
        }
    }
}
