import AppKit
import ServiceManagement
import SwiftUI
import Charts

/// Settings on frosted glass: the desktop shows through, blurred, like a half-transparent pane.
final class SettingsWindowController: NSWindowController {
    convenience init(model: AppModel) {
        // Extra top padding: the content runs under the transparent title bar. The content scrolls,
        // so the window can be shorter than it (small screens); it opens no taller than the screen.
        let natural = NSHostingView(rootView: SettingsView(model: model).padding(.top, 18)).fittingSize
        let host = NSHostingView(rootView: ScrollView(.vertical) { SettingsView(model: model).padding(.top, 18) }
            .scrollIndicators(.automatic))
        host.translatesAutoresizingMaskIntoConstraints = false
        let screen = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        let size = NSSize(width: natural.width, height: min(natural.height, screen.height - 60))

        let glass = NSVisualEffectView()
        glass.material = .underWindowBackground
        glass.blendingMode = .behindWindow
        glass.state = .active
        glass.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: glass.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: glass.trailingAnchor),
            host.topAnchor.constraint(equalTo: glass.topAnchor),
            host.bottomAnchor.constraint(equalTo: glass.bottomAnchor),
        ])

        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "MenuBuddy"
        window.titlebarAppearsTransparent = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentView = glass
        // Drag the top or bottom edge to resize; the width stays the content's width.
        window.contentMinSize = NSSize(width: natural.width, height: 360)
        window.contentMaxSize = NSSize(width: natural.width, height: natural.height)
        window.isReleasedWhenClosed = false
        self.init(window: window)
        window.center()
    }

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var insights = Insights.shared
    @Environment(\.colorScheme) private var scheme
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled
    @State private var lower = Lower.options
    @State private var confirmReset = false   // Reset asks once: first click shows a red "Reset?"
    var showInsights = false   // the Insights tab first (for --settings-snapshot … --insights)
    enum Lower: String, CaseIterable { case options = "Options", insights = "Insights" }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if !model.trusted { accessBanner }

            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Theme").font(.headline)
                    VStack(spacing: 2) {
                        ForEach(model.themes) { theme in themeRow(theme) }
                    }
                }
                .frame(width: 230)

                VStack(alignment: .leading, spacing: 8) {
                    Text(model.trusted && model.appsJSON != "[]" ? "Preview with your menu bar apps" : "Preview")
                        .font(.headline)
                    ThemePreview(themeID: model.themeID,
                                 appsJSON: model.appsJSON == "[]" ? model.demoJSON : model.appsJSON,
                                 onOpen: { id in
                                     if let entry = model.entry(id: id) { MenuBarScanner.press(entry) {} }
                                 },
                                 onMove: { id, to in model.move(id, onto: to) },
                                 onHide: { id in model.hide(id) })
                        .frame(width: 560, height: 430)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.12)))
                    Text("Point at an app to see it grow. Click it to open its menu. Drag it onto another app to swap spots, or onto “Drop here to hide”.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Divider()

            Picker("", selection: $lower) {
                ForEach(Lower.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 240)

            // Options and Insights take turns in the lower half, so the window keeps one size.
            ZStack(alignment: .topLeading) {
                HStack(alignment: .top, spacing: 24) {
                    options.frame(width: 390, alignment: .leading)
                    appsList
                }
                .opacity(lower == .options ? 1 : 0)
                .allowsHitTesting(lower == .options)
                insightsView
                    .opacity(lower == .insights ? 1 : 0)
                    .allowsHitTesting(lower == .insights)
            }
        }
        .padding(22)
        .frame(width: 852)
        .onAppear { if showInsights { lower = .insights } }
    }

    // MARK: - Insights

    private var insightsView: some View {
        let one = { (x: Double) in x < 10 ? String(format: "%.1f", x) : String(Int(x.rounded())) }
        let top = insights.topApps(5)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Insights").font(.headline)
                Text("since \(insights.data.since.formatted(date: .abbreviated, time: .omitted)) · kept on this Mac only")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(confirmReset ? "Reset?" : "Reset") {
                    if confirmReset {
                        insights.reset()
                        confirmReset = false
                    } else {
                        confirmReset = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { confirmReset = false }
                    }
                }
                .buttonStyle(.borderedProminent)        // filled, so the red shows: red "Reset?", grey "Reset"
                .tint(confirmReset ? .red : Color(nsColor: .systemGray))
                .help(confirmReset ? "Click again to clear all Insights counts" : "Clear all Insights counts")
                .disabled(insights.data.opens == 0 && insights.data.clicks == 0)
            }
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    stat("\(insights.data.opens)", "times opened", "\(one(insights.opensPerDay)) a day · \(insights.todayCounts.opens) today")
                    stat("\(insights.data.clicks)", "apps clicked", "\(one(insights.clicksPerDay)) a day · \(insights.todayCounts.clicks) today")
                }
                lastTwoWeeks
                }
                .frame(width: 390, alignment: .leading)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Clicked most").font(.subheadline.weight(.semibold))
                    if top.isEmpty {
                        Text("Click an app in the drop-down and it shows up here.").font(.caption).foregroundStyle(.secondary)
                    } else {
                        let most = max(1, top[0].clicks)
                        ForEach(Array(top.enumerated()), id: \.offset) { _, app in
                            HStack(spacing: 8) {
                                Text(app.name).lineLimit(1).frame(width: 130, alignment: .leading)
                                GeometryReader { g in
                                    RoundedRectangle(cornerRadius: 3).fill(Color.accentColor.opacity(0.75))
                                        .frame(width: max(3, g.size.width * CGFloat(app.clicks) / CGFloat(most)), height: 8)
                                        .frame(maxHeight: .infinity, alignment: .center)
                                }
                                Text("\(app.clicks)").monospacedDigit().frame(width: 40, alignment: .trailing)
                            }
                            .frame(height: 16)
                        }
                    }
                }
            }
        }
    }

    /// Opens and clicks for each of the last 14 days.
    private var lastTwoWeeks: some View {
        let rows = insights.lastDays(14)
        return VStack(alignment: .leading, spacing: 4) {
            Text("Last 14 days").font(.subheadline.weight(.semibold))
            Chart {
                ForEach(rows, id: \.day) { row in
                    BarMark(x: .value("Day", row.day, unit: .day), y: .value("Count", row.opens))
                        .foregroundStyle(by: .value("What", "Opened"))
                        .position(by: .value("What", "Opened"))
                    BarMark(x: .value("Day", row.day, unit: .day), y: .value("Count", row.clicks))
                        .foregroundStyle(by: .value("What", "Clicked"))
                        .position(by: .value("What", "Clicked"))
                }
            }
            .chartLegend(position: .top, alignment: .trailing)
            .chartXAxis { AxisMarks(values: .stride(by: .day, count: 3)) { _ in AxisValueLabel(format: .dateTime.month(.abbreviated).day()) } }
            .frame(width: 380, height: 110)
        }
    }

    private func stat(_ value: String, _ label: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 26, weight: .semibold)).monospacedDigit()
            Text(label).font(.subheadline)
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(width: 185, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
    }

    private var appsList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Your apps").font(.headline)
                Spacer()
                Button("Reset Order") { model.resetOrder() }
                    .disabled(model.order.isEmpty)
                Button("Show All") { model.showAllHidden() }
                    .disabled(model.hiddenKeys.isEmpty)
            }
            if model.entries.isEmpty {
                Text(model.trusted ? "No menu bar apps found." : "Turn on Accessibility to see your apps here.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 200)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
            } else {
                List {
                    ForEach(model.arranged, id: \.key) { entry in appRow(entry) }
                        .onMove { model.moveArranged(from: $0, to: $1) }
                }
                .scrollContentBackground(.hidden)
                .background(Color.primary.opacity(0.06))
                .frame(height: 200)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            Text("Drag rows to reorder. The eye hides an app from MenuBuddy (its menu bar icon stays). Right-click an app in the drop-down for more.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func appRow(_ entry: MenuBarEntry) -> some View {
        let hidden = model.hiddenKeys.contains(entry.key)
        return HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
            Image(nsImage: IconRenderer.image(entry.icon))
                .resizable()
                .frame(width: 20, height: 20)
            Text(entry.name).lineLimit(1)
            Spacer()
            Button {
                model.setHidden(entry.key, !hidden)
            } label: {
                Image(systemName: hidden ? "eye.slash" : "eye")
            }
            .buttonStyle(.borderless)
            .help(hidden ? "Show in MenuBuddy" : "Hide from MenuBuddy")
        }
        .opacity(hidden ? 0.5 : 1)
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Behaviour").font(.headline)
            Toggle("Open when the pointer rests on the MenuBuddy icon", isOn: $model.hoverToOpen)
            Toggle("Also open from the top-right corner of the screen", isOn: $model.hotCorner)
            Toggle("Only show icons hidden behind the notch", isOn: $model.onlyHidden)
                .disabled(!model.hasNotch)
                .help(model.hasNotch ? "" : "This display has no notch.")
            Toggle("Include Apple's own icons (Wi-Fi, battery, clock…)", isOn: $model.includeSystem)
            Toggle("Open at login", isOn: $openAtLogin)
                .onChange(of: openAtLogin) { on in
                    do {
                        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                    } catch {
                        NSLog("MenuBuddy login item: \(error.localizedDescription)")
                    }
                    openAtLogin = SMAppService.mainApp.status == .enabled
                }
            Text("Right-click the MenuBuddy icon for Settings and Quit. ⌘-drag it in the menu bar to move it.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
        }
    }

    private var accessBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "hand.raised.fill").font(.title2).foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Turn on Accessibility for MenuBuddy").font(.headline)
                Text("It needs this to see your menu bar icons and click them for you. System Settings → Privacy & Security → Accessibility.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text("Already switched on? Select MenuBuddy there, remove it with −, then switch it on again when it reappears.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Open System Settings") { model.requestAccess() }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.12)))
    }

    private func themeRow(_ theme: ThemeInfo) -> some View {
        let selected = theme.id == model.themeID
        return Button {
            model.themeID = theme.id
        } label: {
            HStack(spacing: 10) {
                Image(nsImage: StatusIcon.image(theme: theme.id, dark: scheme == .dark))
                    .frame(width: 22, height: 22)
                Text(theme.name)
                if theme.limited == true {
                    Text("Limited")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color(red: 0.80, green: 0.13, blue: 0.20)))
                }
                Spacer()
                if selected { Image(systemName: "checkmark").font(.body.weight(.semibold)) }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 7).fill(selected ? Color.accentColor.opacity(0.18) : Color.clear))
        }
        .buttonStyle(.plain)
    }
}

/// The selected theme, live, hanging from a strip that stands in for the menu bar.
struct ThemePreview: NSViewRepresentable {
    let themeID: String
    let appsJSON: String
    let onOpen: (String) -> Void
    let onMove: (String, String) -> Void
    let onHide: (String) -> Void

    func makeNSView(context: Context) -> PreviewHostView { PreviewHostView() }

    func updateNSView(_ view: PreviewHostView, context: Context) {
        view.themeView.onOpen = onOpen
        view.themeView.onMove = onMove
        view.themeView.onHide = onHide
        view.update(theme: themeID, appsJSON: appsJSON)
    }
}

final class PreviewHostView: NSView {
    let themeView = ThemeView()
    private let barHeight: CGFloat = 26
    private var themeID = ""
    private var appsJSON = ""

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(themeView.webView)
        themeView.onSize = { [weak self] _ in self?.needsLayout = true; self?.needsDisplay = true }
        themeView.onReady = { [weak self] in
            guard let self else { return }
            self.themeView.setApps(self.appsJSON, message: "Nothing to show yet.")
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(theme: String, appsJSON: String) {
        let themeChanged = theme != themeID
        self.appsJSON = appsJSON
        if themeChanged {
            themeID = theme
            themeView.load(theme: theme)
        } else {
            themeView.setApps(appsJSON, message: "Nothing to show yet.", quiet: true)
        }
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        let size = themeView.contentSize
        let room = NSSize(width: bounds.width - 12, height: bounds.height - barHeight - 6)
        let scale = max(0.3, min(1, room.width / size.width, room.height / size.height))
        themeView.webView.pageZoom = scale
        let w = (size.width * scale).rounded(), h = (size.height * scale).rounded()
        themeView.webView.frame = NSRect(x: ((bounds.width - w) / 2).rounded(), y: barHeight, width: w, height: h)
    }

    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        (dark ? NSColor(calibratedRed: 0.17, green: 0.19, blue: 0.24, alpha: 1)
              : NSColor(calibratedRed: 0.80, green: 0.84, blue: 0.90, alpha: 1)).setFill()
        bounds.fill()
        (dark ? NSColor(white: 0.12, alpha: 0.9) : NSColor(white: 1, alpha: 0.75)).setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: barHeight).fill()
        let icon = StatusIcon.image(theme: themeID, dark: dark)
        let webFrame = themeView.webView.frame
        let x = webFrame.minX + webFrame.width * themeView.anchor
        icon.draw(in: NSRect(x: x - 9.5, y: (barHeight - 19) / 2, width: 19, height: 19), from: .zero,
                  operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}
