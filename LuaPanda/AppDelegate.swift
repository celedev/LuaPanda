//
//  AppDelegate.swift
//  LuaPanda
//

import Cocoa

@NSApplicationMain
class AppDelegate: NSObject, NSApplicationDelegate {

    private var luaContext: CIMLuaContext?
    private var contextMonitor: CIMLuaContextMonitor?


    func applicationDidFinishLaunching(aNotification: NSNotification) {
        // Insert code here to initialize your application
        
        // CIMLuaContext.declareObjcMethodsInvocationLockProtectedClass(NSKeyedUnarchiver)
        
        // Create a Lua Context and load the initial Lua module
        luaContext = CIMLuaContext(name: "LuaContext")
        contextMonitor = CIMLuaContextMonitor(luaContext: luaContext, connectionTimeout: 15, showWaitingMessage: true)
        luaContext?.loadLuaModuleNamed("GameViewController", withCompletionBlock:nil)
        
    }

    func applicationWillTerminate(aNotification: NSNotification) {
        // Insert code here to tear down your application
    }

    func applicationShouldTerminateAfterLastWindowClosed(sender: NSApplication) -> Bool {
        return true
    }

}

