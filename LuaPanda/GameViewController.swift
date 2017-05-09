//
//  ViewController.swift
//  LuaPanda
//

import simd
import GameController

@objc protocol GameControlsHandler {
    @objc optional func panCamera(dx x:Float, dy y: Float)
}


class GameViewController: NSViewController, GameControlsHandler {

    // Game view
    var gameView: GameView {
        return view as! GameView
    }
    
    // Game controls
    internal var controllerDPad: GCControllerDirectionPad?
    internal var controllerStoredDirection = float2(0.0) // left/right up/down
    
    #if os(OSX)
    internal var lastMousePosition = float2(0)
    #elseif os(iOS)
    internal var padTouch: UITouch?
    internal var panningTouch: UITouch?
    #endif
    
    override func viewDidLoad() {
        super.viewDidLoad()

        // Do any additional setup after loading the view.
        #if os(OSX)
        gameView.eventsDelegate = self
        #endif
        
        // If the Lua extension for this class has not been loaded yet, register to "Lua module loaded" notification, 
        // and  do the Lua setup for this object once this Lua extension is loaded
        let luaContext = CIMLuaContext.default()
        if (luaContext == nil) || !luaContext!.isLuaClassExtensionLoaded(for: type(of: self)) {
            
            NotificationCenter.default.addObserver(self, selector: #selector(GameViewController.handleLuaModuleLoadedNotification), 
                                                             name: NSNotification.Name.cimLuaModuleLoaded, object: nil)
        }
    }

    override var representedObject: Any? {
        didSet {
        // Update the view, if already loaded.
        }
    }

    func handleLuaModuleLoadedNotification(_ notification: Notification) {
        
        let moduleName = notification.userInfo! [kCIMLuaModuleLoadedNotificationKeyModuleName] as! String
        if moduleName == String(describing: type(of: self)) {
            // The loaded Lua module extending this class is now loaded and we can do any necessary setup in Lua
            (self as! CIMLuaObject).doLuaSetupIfNeeded()
            
            NotificationCenter.default.removeObserver(self, name: NSNotification.Name.cimLuaModuleLoaded, object: nil)
            
        }
    }
}
