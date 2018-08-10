import Realm
import RealmSwift

/// Represents the expiry of a cached object
public enum CacheExpiry {
    case never
    case seconds(TimeInterval)
    case date(Foundation.Date)
}

/// A generic cache that persists objects to disk and is backed by a NSCache.
/// Supports an expiry date for every cached object. Expired objects are automatically deleted upon their next access via `objectForKey:`.
/// If you want to delete expired objects, call `removeAllExpiredObjects`.
///
/// Subclassing notes: This class fully supports subclassing.
/// The easiest way to implement a subclass is to override `objectForKey` and `setObject:forKey:expires:`,
/// e.g. to modify values prior to reading/writing to the cache.


private let CurrentDBSchemaVersion: UInt64 = 10
private lazy var realmDB: Realm = { _ throws -> Realm in
    let migrationBlock: MigrationBlock = { migration, oldSchemaVersion in
        //Leave the block empty
    }
    let fileURL = RLMRealmPathForFile("mc_cache.realm")
    
    Realm.Configuration.defaultConfiguration = Realm.Configuration(fileURL: fileURL, schemaVersion: CurrentDBSchemaVersion, migrationBlock: migrationBlock)
    
    do {
        try Realm.performMigration()
        return try Realm()
    } catch let error {
        throw error
    }
}()

open class Cache<T: NSCoding> {
    open let name: String
    open let cacheDirectory: URL

    internal let cache = NSCache<NSString, InternalCacheObject>() // marked internal for testing
    fileprivate let fileManager = FileManager()
    fileprivate let queue = DispatchQueue(label: "com.mc.cache.diskQueue", attributes: DispatchQueue.Attributes.concurrent)

    /// Typealias to define the reusability in declaration of the closures.
    public typealias CacheBlockClosure = (T, CacheExpiry) -> Void
    public typealias ErrorClosure = (NSError?) -> Void


    // MARK: Initializers

    /// Designated initializer.
    ///
    /// - parameter name: Name of this cache
    ///	- parameter directory:  Objects in this cache are persisted to this directory.
    ///                         If no directory is specified, a new directory is created in the system's Caches directory
    /// - parameter fileProtection: Needs to be a valid value for `NSFileProtectionKey` (i.e. `NSFileProtectionNone`) and 
    ///                             adds the given value as an NSFileManager attribute.
    ///
    ///  - returns:	A new cache with the given name and directory
    public init(name: String, directory: URL?, fileProtection: String? = nil) throws {
        self.name = name
        cache.name = name
        
        _ = try realmDB
    }

    /// Convenience Initializer
    ///
    /// - parameter name: Name of this cache
    ///
    /// - returns	A new cache with the given name and the default cache directory
    public convenience init(name: String) throws {
        try self.init(name: name, directory: nil)
    }


    // MARK: Awesome caching

    /// Returns a cached object immediately or evaluates a cacheBlock.
    /// The cacheBlock will not be re-evaluated until the object is expired or manually deleted.
    /// If the cache already contains an object, the completion block is called with the cached object immediately.
    ///
    /// If no object is found or the cached object is already expired, the `cacheBlock` is called.
    /// You might perform any tasks (e.g. network calls) within this block. Upon completion of these tasks,
    /// make sure to call the `success` or `failure` block that is passed to the `cacheBlock`.
    /// The completion block is invoked as soon as the cacheBlock is finished and the object is cached.
    ///
    /// - parameter key:			The key to lookup the cached object
    /// - parameter cacheBlock:	This block gets called if there is no cached object or the cached object is already expired.
    ///                         The supplied success or failure blocks must be called upon completion.
    ///                         If the error block is called, the object is not cached and the completion block is invoked with this error.
    /// - parameter completion: Called as soon as a cached object is available to use. The second parameter is true if the object was already cached.
    open func setObject(forKey key: String, cacheBlock: (@escaping CacheBlockClosure, @escaping ErrorClosure) -> Void, completion: @escaping (T?, Bool, NSError?) -> Void) {
        if let object = object(forKey: key) {
            completion(object, true, nil)
        } else {
            let successBlock: CacheBlockClosure = { (obj, expires) in
                self.setObject(obj, forKey: key, expires: expires)
                completion(obj, false, nil)
            }

            let failureBlock: ErrorClosure = { (error) in
                completion(nil, false, error)
            }

            cacheBlock(successBlock, failureBlock)
        }
    }


    // MARK: Get object

    /// Looks up and returns an object with the specified name if it exists.
    /// If an object is already expired, `nil` will be returned.
    ///
    /// - parameter key: The name of the object that should be returned
    /// - parameter returnExpiredObjectIfPresent: If set to `true`, an expired 
    ///             object may be returned if present. Defaults to `false`.
    ///
    /// - returns: The cached object for the given name, or nil
    
    private func objKey(with value: String) -> String {
        return "\(self.name)_\(value)"
    }
    
    open func object(forKey key: String, returnExpiredObjectIfPresent: Bool = false) -> T? {
        let ckey = objKey(with: key)
        
        let predicate = NSPredicate(format: "key == \(ckey)")
        let object: CacheObject? = realmDB.objects(CacheObject.self)
                                    .first(where: { obj in (obj.key == ckey) })
        
        // Check if object is not already expired and return
        if let object = object, !object.isExpired() || returnExpiredObjectIfPresent {
            return object.getValue() as? T
        }

        return nil
    }

    open func allObjects(includeExpired: Bool = false) -> [T] {
        let cached: [CacheObject]? = try? realmDB.objects(CacheObject.self)
            .filter { item in (item.key.hasPrefix(self.name)) }
        let objects: [T] = cached?.flatMap { $0.getValue() } ?? []
        return objects
    }

    open func isOnMemory(forKey key: String) -> Bool {
        return cache.object(forKey: key as NSString) != nil
    }


    // MARK: Set object

    /// Adds a given object to the cache.
    /// The object is automatically marked as expired as soon as its expiry date is reached.
    ///
    /// - parameter object:	The object that should be cached
    /// - parameter forKey:	A key that represents this object in the cache
    /// - parameter expires: The CacheExpiry that indicates when the given object should be expired
    open func setObject(_ object: T, forKey key: String, expires: CacheExpiry = .never) {
        let ckey = objKey(with: key)
        let expiryDate = expiryDateForCacheExpiry(expires)
        // TODO: add realm
        queue.sync(flags: .barrier, execute: {
            self.add(object, key: ckey, expiryDate: expiryDate)
        }) 
    }

    // MARK: Remove objects

    /// Removes an object from the cache.
    ///
    /// - parameter key: The key of the object that should be removed
    open func removeObject(forKey key: String) {
        let ckey = objKey(with: key)
        queue.sync(flags: .barrier, execute: {
            do {
                try realmDB.write {
                    if let objectForRemove: CacheObject? = try? realmDB.objects(CacheObject.self)
                        .first({ $0.key == ckey }) {
                        realmDB.delete(objectForRemove)
                    }
                }
            } catch { }
        }) 
    }

    /// Removes all objects from the cache.
    open func removeAllObjects() {
        
        // TODO: add predicate
        queue.sync(flags: .barrier, execute: {
            do {
                try realmDB.write {
                    let predicate = NSPredicate(format: "key BEGINSWITH \(self.name)")
                    let objectsForRemove: [CacheObject] = realmDB.objects(CacheObject.self).filter(predicate)
                    if objectsForRemove.count > 0 {
                        realmDB.delete(objectsForRemove)
                    }
                }
            } catch { }
        }) 
    }

    /// Removes all expired objects from the cache.
    open func removeExpiredObjects() {
        // TODO: add realm
        queue.sync(flags: .barrier, execute: {
            do {
                try realmDB.write {
                    let objectsForRemove: [CacheObject] = (try? realmDB.objects(CacheObject.self)
                                        .filter({ item -> Bool in
                                            (item.key.hasPrefix(self.name) && item.isExpired())
                                        }) ) ?? []
                    if objectsForRemove.count > 0 {
                        realmDB.delete(objectsForRemove)
                    }
                }
            } catch { }
        }) 
    }

    // MARK: Subscripting

    open subscript(key: String) -> T? {
        get {
            return object(forKey: key)
        }
        set(newValue) {
            if let value = newValue {
                setObject(value, forKey: key)
            } else {
                removeObject(forKey: key)
            }
        }
    }

    // MARK: Private Helper (not thread safe)

    fileprivate func add(_ object: T, key: String, expiryDate: Date) {
        // TODO: add realm
        let ckey = objKey(with: key)
        // Set object in local cache
        cache.setObject(object, forKey: ckey as NSString)

        do {
            try realmDB.write {
                let cacheObject = CacheObject(key: key, value: object, expiryDate: expiryDate)
                realmDB.add(cacheObject, update: true)
            }
        } catch {
            
        }
    }

    fileprivate func read(_ key: String) -> CacheObject? {
        // TODO: add realm
        let ckey = objKey(with: key)
        let object: CacheObject? = realmDB.objects(CacheObject.self)
            .first(where: { $0.key == ckey })
        return object
    }

    // Deletes an object from disk
    fileprivate func removeFromDisk(_ key: String) {
        let url = self.urlForKey(key)
        _ = try? self.fileManager.removeItem(at: url)
    }


    // MARK: Private Helper

    fileprivate func allKeys() -> [String] {
        let urls = try? self.fileManager.contentsOfDirectory(at: self.cacheDirectory, includingPropertiesForKeys: nil, options: [])
        return urls?.flatMap { $0.deletingPathExtension().lastPathComponent } ?? []
    }

    fileprivate func urlForKey(_ key: String) -> URL {
        let k = sanitizedKey(key)
        return cacheDirectory
            .appendingPathComponent(k)
            .appendingPathExtension("cache")
    }

    fileprivate func sanitizedKey(_ key: String) -> String {
        return key.replacingOccurrences(of: "[^a-zA-Z0-9_]+", with: "-", options: .regularExpression, range: nil)
    }

    fileprivate func expiryDateForCacheExpiry(_ expiry: CacheExpiry) -> Date {
        switch expiry {
        case .never:
            return Date.distantFuture
        case .seconds(let seconds):
            return Date().addingTimeInterval(seconds)
        case .date(let date):
            return date
        }
    }
}
