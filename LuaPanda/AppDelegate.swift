//
//  AppDelegate.swift
//  LuaPanda
//

import Cocoa

@NSApplicationMain
class AppDelegate: NSObject, NSApplicationDelegate {

    private var luaContext: CIMLuaContext?
    private var contextMonitor: CIMLuaContextMonitor?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Insert code here to initialize your application
        
        // Create a Lua Context and load the initial Lua module
        luaContext = CIMLuaContext(name: "LuaContext")
        contextMonitor = CIMLuaContextMonitor(luaContext: luaContext, connectionTimeout: 15, showWaitingMessage: true)
        luaContext?.loadLuaModuleNamed("Start", withCompletionBlock:nil)
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        // Insert code here to tear down your application
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

}

