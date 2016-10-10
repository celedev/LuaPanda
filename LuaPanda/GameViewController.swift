//
//  ViewController.swift
//  LuaPanda
//

import simd
import GameController

@objc protocol GameControlsHandler {
    optional func panCamera(dx x:Float, dy y: Float)
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
        let luaContext = CIMLuaContext.defaultLuaContext()
        if (luaContext == nil) || !luaContext!.isLuaClassExtensionLoadedForClass(self.dynamicType) {
            
            NSNotificationCenter.defaultCenter().addObserver(self, selector: #selector(GameViewController.handleLuaModuleLoadedNotification), 
                                                             name: kCIMLuaModuleLoadedNotification, object: nil)
        }
    }

    override var representedObject: AnyObject? {
        didSet {
        // Update the view, if already loaded.
        }
    }

    func handleLuaModuleLoadedNotification(notification: NSNotification) {
        
        let moduleName = notification.userInfo! [kCIMLuaModuleLoadedNotificationKeyModuleName] as! String
        if moduleName == String(self.dynamicType) {
            // The loaded Lua module extending this class is now loaded and we can do any necessary setup in Lua
            (self as! CIMLuaObject).doLuaSetupIfNeeded()
            
            NSNotificationCenter.defaultCenter().removeObserver(self, name: kCIMLuaModuleLoadedNotification, object: nil)
            
        }
    }
}
