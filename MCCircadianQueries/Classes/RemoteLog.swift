//
//  RemoteLog.swift
//  MCCircadianQueries
//
//  Created by Yanif Ahmad on 1/15/17. 
//  Copyright © 2017 Yanif Ahmad, Tom Woolf. All rights reserved. 
//


import Foundation
//import Async
//import LogKit
//import SwiftyUserDefaults

private let RLEnabledKey    = "RLEnabledKey"
private let RLTokenKey      = "RLTokenKey"
private let RLConfigNameKey = "RLConfigNameKey"
private let RLConfigDataKey = "RLConfigDataKey"

public enum LogType {
    case local
    case remote
}

public let MCInitLogConfigName = "Minimal"

private let MCDeviceId = "<no-id>"

private let MCFormatter: (String) -> LXEntryFormatter = { deviceId in return LXEntryFormatter({ e in
    String(format: "%@ [%@] %@ %@ <%@:%d> %@", e.dateTime, e.level.uppercased(), deviceId, e.functionName, e.fileName, e.lineNumber, e.message)
})}

open class RemoteLog {

    open static let sharedInstance = RemoteLog()

    fileprivate var log : LXLogger = LXLogger(endpoints: [LXConsoleEndpoint(synchronous: false, entryFormatter: MCFormatter(MCDeviceId))])
        // Start with an asynchronous logger to handle races w/ other threads during app initialization.

//    fileprivate var console = Levels.LXConsoleEndpoint(entryFormatter: MCFormatter(MCDeviceId))
//    fileprivate var console = LXConsoleEndpoint(synchronous: false, minimumPriorityLevel: .all, dateFormatter: .standardFormatter(), entryFormatter: .standardFormatter())
    fileprivate var console = LXConsoleEndpoint(synchronous: false, minimumPriorityLevel: .all, dateFormatter: .standardFormatter(), entryFormatter: .standardFormatter())
        // Handle to a synchronous console logger, which should never be deinit'ed due to it closing stderr.

    open var url : URL! = nil
    open var logType: LogType = .local

    open var configName: String = MCInitLogConfigName
    open var config: [String: AnyObject] = [:]
    open var logModules : [String: String] = [:]

    fileprivate var deviceId: String = MCDeviceId

    // A serialized queue for log configuration.
    open let configQueue = DispatchQueue(label: "LogQueue", attributes: [])

    init() {
        self.loadURL(true)
        self.loadLogConfig(true)
        self.loadRemote(true)
    }

    open func setDeviceId(_ deviceId: String) {
        Async.custom(queue: configQueue) {
            self.deviceId = deviceId
            self.console.entryFormatter = MCFormatter(self.deviceId)
        }
    }

    func setLogger() {
        Async.custom(queue: configQueue) {
            switch self.logType {
            case .local:
//                self.log = LXLogger(endpoints: [self.console])
                self.log = LXLogger(endpoints: [self.console])
            case .remote:
                if let url = self.url {
//                    self.log = LXLogger(endpoints: [
                    self.log = LXLogger(endpoints: [
                        self.console,
//                        LXHTTPEndpoint(URL: url, HTTPMethod: "POST", entryFormatter: MCFormatter(self.deviceId))
//                        LXHTTPEndpoint(URL: url, HTTPMethod: "POST", successCodes: {200, 201, 202, 204}, sessionConfiguration: .defaultSessionConfiguration(), minimumPriorityLevel: .All, dateFormatter: .standardFormatter(), entryFormatter: .standardFormatter())
                        LXHTTPEndpoint(URL: url, HTTPMethod: "POST", sessionConfiguration: .default, minimumPriorityLevel: .all, dateFormatter: .standardFormatter(), entryFormatter: .standardFormatter())
                    ])
                } else {
//                    self.log = LXLogger(endpoints: [self.console])
                    self.log = LXLogger(endpoints: [self.console])
                    self.logType = .local
                    self.error("Could not switch to remote logging (invalid URL)")
                }
            }
        }
    }

    open func loadURL(_ initial: Bool = false) {
        if Defaults.hasKey(RLTokenKey) {
            if let s = Defaults.string(forKey: RLTokenKey), s.characters.count > 0 {
                self.setURL(s, initial: initial)
            } else {
                Defaults.remove(RLTokenKey)
                Defaults.synchronize()
            }
        }
    }

    open func setURL(_ token: String, initial: Bool = false) {
        if token.characters.count > 0 {
            if let u = URL(string: "http://logs-01.loggly.com/inputs/\(token)/tag/http") {
                Async.custom(queue: configQueue) {
                    if !initial {
                        Defaults.set(token, forKey: RLTokenKey)
                        Defaults.synchronize()
                    }
                    self.url = u
                }
            }
        }
    }

    open func loadRemote(_ initial: Bool = false) {
        var remote = self.logType == .remote
        if Defaults.hasKey(RLEnabledKey) {
            remote = Defaults.bool(forKey: RLEnabledKey)
        }

        self.setRemote(remote, initial: initial)
    }

    open func setRemote(_ on: Bool, initial: Bool = false) {
        if on != remote() || initial {
            Async.custom(queue: configQueue) {
                self.info("Remote logging \(on) (initial: \(initial))")
                if !initial {
                    Defaults.set(on, forKey: RLEnabledKey)
                    Defaults.synchronize()
                }
                self.logType = on ? .remote : .local
                self.setLogger()
            }
        }
        else {
            self.info("Remote logging unchanged")
        }
    }

    open func remote() -> Bool {
        return logType == .remote
    }

//    open func priority(_ p: String) -> LXPriorityLevel? {
    open func priority(_ p: String) -> LXPriorityLevel? {
        switch p.lowercased() {
        case "all":
            return .all

        case "debug":
            return .debug

        case "info":
            return .info

        case "notice":
            return .notice

        case "warning":
            return .warning

        case "error":
            return .error

        case "critical":
            return .critical

        case "none":
            return .none

        default:
            return nil
        }
    }

    open func loadLogConfig(_ initial: Bool = false) {
        if Defaults.hasKey(RLConfigNameKey) && Defaults.hasKey(RLConfigDataKey) {
            if let n = Defaults.string(forKey: RLConfigNameKey), let cfg = Defaults.dictionary(forKey: RLConfigDataKey) {
                self.setLogConfig(n, cfg: cfg as [String : AnyObject], initial: initial)
            } else {
                Defaults.remove(RLConfigNameKey)
                Defaults.remove(RLConfigDataKey)
                Defaults.synchronize()
            }
        }
    }

    open func setLogConfig(_ name: String, cfg: [String: AnyObject], initial: Bool = false) {
        Async.custom(queue: configQueue) {
            if !initial {
                Defaults.set(name, forKey: RLConfigNameKey)
 //               Defaults.set(cfg, forKey: RLConfigDataKey)
                Defaults.synchronize()
            }
            self.configName = name
            self.config = cfg
        }
    }

    open func setLogModules(_ modules: [String: String]) {
        Async.custom(queue: configQueue) { self.logModules = modules }
    }

//    func logMsg(_ msg: String, feature: String = "", level: LXPriorityLevel, fnName: String, fPath: String, ln: Int, col: Int) {
        func logMsg(_ msg: String, feature: String = " ", level: LXPriorityLevel, fnName: String, fPath: String, ln: Int, col: Int) {
//        var globalLevel : LXPriorityLevel = .info
        var globalLevel : LXPriorityLevel = .info
        if let g = config["default"] as? String, let p = priority(g) {
            globalLevel = p
        }

//        var testLevel : LXPriorityLevel = globalLevel
        var testLevel : LXPriorityLevel = globalLevel

        let fName = (fPath as NSString).lastPathComponent

        // Log level matching hierarchy: module x feature => module => global
        if let mName = logModules[fName] {
            if let fConfig = config[mName] as? [String:Int] {
//                let mDefaultLevel = LXPriorityLevel(rawValue: fConfig["default"] ?? globalLevel.rawValue) ?? globalLevel
                let mDefaultLevel = LXPriorityLevel(rawValue: fConfig["default"] ?? globalLevel.rawValue) ?? globalLevel
//                if let mfLevel = LXPriorityLevel(rawValue: fConfig[feature] ?? mDefaultLevel.rawValue), feature.characters.count > 0 {
                if let mfLevel = LXPriorityLevel(rawValue: fConfig[feature] ?? mDefaultLevel.rawValue), feature.characters.count > 0 {
                    testLevel = mfLevel
                } else {
                    testLevel = mDefaultLevel
                }
            }
            else if let mLevel = LXPriorityLevel(rawValue: (config[mName] as? Int) ?? testLevel.rawValue) {
                testLevel = mLevel
            }
        }

        if level >= testLevel {
            switch level {
            case .debug:
                log.debug(msg, functionName: fnName, filePath: fPath, lineNumber: ln, columnNumber: col)

            case .info:
                log.info(msg, functionName: fnName, filePath: fPath, lineNumber: ln, columnNumber: col)

            case .warning:
                log.warning(msg, functionName: fnName, filePath: fPath, lineNumber: ln, columnNumber: col)

            case .error:
                log.error(msg, functionName: fnName, filePath: fPath, lineNumber: ln, columnNumber: col)

            default:
                break
            }
        }
    }

    open func debug(_ msg: String, feature: String = "", fnName: String = #function, fPath: String = #file, ln: Int = #line, col: Int = #column) {
        logMsg(msg, feature: feature, level: .debug, fnName: fnName, fPath: fPath, ln: ln, col: col)
    }

    open func info(_ msg: String, feature: String = "", fnName: String = #function, fPath: String = #file, ln: Int = #line, col: Int = #column) {
        logMsg(msg, feature: feature, level: .info, fnName: fnName, fPath: fPath, ln: ln, col: col)
    }

    open func warning(_ msg: String, feature: String = "", fnName: String = #function, fPath: String = #file, ln: Int = #line, col: Int = #column) {
        logMsg(msg, feature: feature, level: .warning, fnName: fnName, fPath: fPath, ln: ln, col: col)
    }
    
    open func error(_ msg: String, feature: String = "", fnName: String = #function, fPath: String = #file, ln: Int = #line, col: Int = #column) {
        logMsg(msg, feature: feature, level: .error, fnName: fnName, fPath: fPath, ln: ln, col: col)
    }
}
