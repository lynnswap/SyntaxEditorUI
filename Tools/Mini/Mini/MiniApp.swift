import SyntaxEditorUI

private func prepareBundledSyntaxLanguages() {
    Task.detached {
        await SyntaxEditorHighlighting.prepare(SyntaxLanguage.allCases)
    }
}

#if canImport(UIKit)
import UIKit

@main
@MainActor
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        prepareBundledSyntaxLanguages()

        if #available(iOS 26.0, *) {
            UIMainMenuSystem.shared.setBuildConfiguration(UIMainMenuSystem.Configuration()) { builder in
                SyntaxEditorMenu.insert(into: builder)
            }
        }
        return true
    }

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(
            name: "Default Configuration",
            sessionRole: connectingSceneSession.role
        )
        configuration.sceneClass = UIWindowScene.self
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }
}

@MainActor
final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }

        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = MiniSplitViewController(
            model: MiniEditorSession(configuration: .current)
        )
        self.window = window
        window.makeKeyAndVisible()
    }
}
#elseif canImport(AppKit)
import AppKit
import ObservationBridge

@objc
private protocol MiniUndoRedoMenuActions: AnyObject {
    func undo(_ sender: Any?)
    func redo(_ sender: Any?)
}

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static var sharedDelegate: AppDelegate?
    private var windowController: MiniWindowController?

    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        sharedDelegate = delegate
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        application.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        prepareBundledSyntaxLanguages()
        installStandardMainMenuIfNeeded()

        let windowController = MiniWindowController(
            model: MiniEditorSession(configuration: .current)
        )
        self.windowController = windowController
        windowController.showWindow(nil)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func installStandardMainMenuIfNeeded() {
        let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? ProcessInfo.processInfo.processName

        let mainMenu = NSMenu(title: "Main Menu")

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu(title: appName)
        appMenu.addItem(
            withTitle: "About \(appName)",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        appMenu.addItem(.separator())
        let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu(title: "Services")
        servicesItem.submenu = servicesMenu
        appMenu.addItem(servicesItem)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide \(appName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthersItem = NSMenuItem(
            title: "Hide Others",
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h"
        )
        hideOthersItem.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthersItem)
        appMenu.addItem(
            withTitle: "Show All",
            action: #selector(NSApplication.unhideAllApplications(_:)),
            keyEquivalent: ""
        )
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Quit \(appName)",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: #selector(MiniUndoRedoMenuActions.undo(_:)), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: #selector(MiniUndoRedoMenuActions.redo(_:)), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        let deleteItem = NSMenuItem(
            title: "Delete",
            action: #selector(NSText.delete(_:)),
            keyEquivalent: String(Character(UnicodeScalar(NSDeleteCharacter)!))
        )
        deleteItem.keyEquivalentModifierMask = []
        editMenu.addItem(deleteItem)
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(.separator())
        let findMenuItem = NSMenuItem(title: "Find", action: nil, keyEquivalent: "")
        let findMenu = NSMenu(title: "Find")
        findMenu.addItem(textFinderMenuItem(title: "Find...", finderAction: .showFindInterface, keyEquivalent: "f"))
        findMenu.addItem(
            textFinderMenuItem(
                title: "Find and Replace...",
                finderAction: .showReplaceInterface,
                keyEquivalent: "f",
                modifiers: [.command, .option]
            )
        )
        findMenu.addItem(.separator())
        findMenu.addItem(textFinderMenuItem(title: "Find Next", finderAction: .nextMatch, keyEquivalent: "g"))
        findMenu.addItem(
            textFinderMenuItem(
                title: "Find Previous",
                finderAction: .previousMatch,
                keyEquivalent: "g",
                modifiers: [.command, .shift]
            )
        )
        findMenu.addItem(
            textFinderMenuItem(title: "Use Selection for Find", finderAction: .setSearchString, keyEquivalent: "e")
        )
        findMenuItem.submenu = findMenu
        editMenu.addItem(findMenuItem)
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        SyntaxEditorMenu.insert(into: mainMenu)

        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(
            withTitle: "Minimize",
            action: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: "m"
        )
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(
            withTitle: "Bring All to Front",
            action: #selector(NSApplication.arrangeInFront(_:)),
            keyEquivalent: ""
        )
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)

        NSApp.mainMenu = mainMenu
        NSApp.servicesMenu = servicesMenu
        NSApp.windowsMenu = windowMenu
    }

    private func textFinderMenuItem(
        title: String,
        finderAction: NSTextFinder.Action,
        keyEquivalent: String,
        modifiers: NSEvent.ModifierFlags = .command
    ) -> NSMenuItem {
        let item = NSMenuItem(
            title: title,
            action: #selector(NSResponder.performTextFinderAction(_:)),
            keyEquivalent: keyEquivalent
        )
        item.keyEquivalentModifierMask = modifiers
        item.tag = finderAction.rawValue
        return item
    }
}

@MainActor
final class MiniWindowController: NSWindowController, NSToolbarDelegate {
    private let model: MiniEditorSession
    private let splitViewController: MiniSplitViewController
    private var modelObservation: PortableObservationTracking.Token?
    private var editorObservation: PortableObservationTracking.Token?
    private var lineWrappingItem: NSToolbarItemGroup?
    private var themePopUpButton: NSPopUpButton?

    init(model: MiniEditorSession) {
        self.model = model
        self.splitViewController = MiniSplitViewController(model: model)

        let window = NSWindow(contentViewController: splitViewController)
        window.setContentSize(NSSize(width: 1000, height: 700))
        window.minSize = NSSize(width: 760, height: 480)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarSeparatorStyle = .automatic
//        window.titleVisibility = .hidden
//        window.titlebarAppearsTransparent = false
        window.toolbarStyle = .unified
        window.center()

        super.init(window: window)

        configureToolbar()
        bindModel()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    isolated deinit {
        modelObservation?.cancel()
        editorObservation?.cancel()
    }

    private func configureToolbar() {
        let toolbar = NSToolbar(identifier: .miniToolbar)
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        window?.toolbar = toolbar
    }

    private func bindModel() {
        modelObservation?.cancel()
        modelObservation = withPortableContinuousObservation { [weak self] _ in
            guard let self else { return }

            renderWindowTitle(model.currentPreset.title)
        }
        bindEditorModel()
    }

    private func bindEditorModel() {
        let editorModel = model.editorModel
        editorObservation?.cancel()
        editorObservation = withPortableContinuousObservation { [weak self, editorModel] _ in
            guard let self else { return }

            updateLineWrappingItem(lineWrappingEnabled: editorModel.lineWrappingEnabled)
            updateThemeItem(selectedThemePreset: editorModel.theme.preset ?? .default)
        }
    }

    private func renderWindowTitle(_ title: String) {
        window?.title = title
    }

    private func updateLineWrappingItem(lineWrappingEnabled: Bool? = nil) {
        lineWrappingItem?.setSelected(
            lineWrappingEnabled ?? model.editorModel.lineWrappingEnabled,
            at: 0
        )
    }

    private func updateThemeItem(selectedThemePreset: SyntaxEditorTheme.Preset? = nil) {
        let selectedRawValue = (selectedThemePreset ?? model.selectedThemePreset).rawValue
        for item in themePopUpButton?.itemArray ?? [] where item.representedObject as? String == selectedRawValue {
            themePopUpButton?.select(item)
            return
        }
    }

    @objc private func toggleLineWrapping() {
        model.editorModel.lineWrappingEnabled.toggle()
    }

    @objc private func selectThemePreset(_ sender: NSPopUpButton) {
        guard let rawValue = sender.selectedItem?.representedObject as? String,
              let preset = SyntaxEditorTheme.Preset(rawValue: rawValue)
        else {
            return
        }

        model.selectedThemePreset = preset
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.sidebarTrackingSeparator, .flexibleSpace, .theme, .lineWrapping]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.sidebarTrackingSeparator, .flexibleSpace, .theme, .lineWrapping]
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        if itemIdentifier == .sidebarTrackingSeparator {
            return NSTrackingSeparatorToolbarItem(
                identifier: itemIdentifier,
                splitView: splitViewController.splitView,
                dividerIndex: 0
            )
        }

        if itemIdentifier == .theme {
            let button = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 178, height: 28), pullsDown: false)
            button.target = self
            button.action = #selector(selectThemePreset(_:))
            for preset in SyntaxEditorTheme.Preset.allCases {
                button.addItem(withTitle: preset.displayName)
                button.lastItem?.representedObject = preset.rawValue
            }
            button.setAccessibilityIdentifier("mini.toolbar.theme")
            themePopUpButton = button
            updateThemeItem()

            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Theme"
            item.paletteLabel = "Theme"
            item.toolTip = "Select theme"
            item.view = button
            return item
        }

        guard itemIdentifier == .lineWrapping else { return nil }

        let image = NSImage(
            systemSymbolName: "text.alignleft",
            accessibilityDescription: "Wrap Lines"
        ) ?? NSImage()
        let item = NSToolbarItemGroup(
            itemIdentifier: itemIdentifier,
            images: [image],
            selectionMode: .selectAny,
            labels: ["Wrap Lines"],
            target: self,
            action: #selector(toggleLineWrapping)
        )
        item.label = "Wrap Lines"
        item.paletteLabel = "Wrap Lines"
        item.toolTip = "Toggle line wrapping"
        item.controlRepresentation = .expanded
        item.view?.setAccessibilityIdentifier("mini.toolbar.lineWrapping")

        lineWrappingItem = item
        updateLineWrappingItem()
        return item
    }
}

private extension NSToolbar.Identifier {
    static let miniToolbar = NSToolbar.Identifier("MiniToolbar")
}

private extension NSToolbarItem.Identifier {
    static let theme = NSToolbarItem.Identifier("Theme")
    static let lineWrapping = NSToolbarItem.Identifier("LineWrapping")
}
#endif
