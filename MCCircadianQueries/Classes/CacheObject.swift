import Realm
import RealmSwift

/// This class is a wrapper around an objects that should be cached to disk.
///
/// NOTE: It is currently not possible to use generics with a subclass of NSObject
/// 	 However, NSKeyedArchiver needs a concrete subclass of NSObject to work correctly
class CacheObject: Object, NSCoding {
    @objc dynamic var key: String = ""
    @objc dynamic var value: Data = Data()
    @objc dynamic var expiryDate: Date = Date()
    
    override class func primaryKey() -> String? {
        return "key"
    }

    /// Designated initializer.
    ///
    /// - parameter value:      An object that should be cached
    /// - parameter expiryDate: The expiry date of the given value
    init(key: String = "", value: CachableObject, expiryDate: Date) {
        self.key = key
        self.expiryDate = expiryDate
        super.init()
        self.setCacheValue(value)
    }

    /// Determines if cached object is expired
    ///
    /// - returns: True If objects expiry date has passed
    func isExpired() -> Bool {
        return expiryDate.isInThePast
    }


    /// NSCoding

    required init?(coder aDecoder: NSCoder) {
        guard let val = aDecoder.decodeObject(forKey: "value"),
              let expiry = aDecoder.decodeObject(forKey: "expiryDate") as? Date else {
                return nil
        }

        self.value = (val as? Data) ?? Data()
        self.expiryDate = expiry
        super.init()
    }

    func encode(with aCoder: NSCoder) {
        aCoder.encode(value, forKey: "value")
        aCoder.encode(expiryDate, forKey: "expiryDate")
    }
    
    enum CodingKeys: String, CodingKey {
        case value, expiryDate
    }
    
    init?(data: Data) throws {
        do {
            let info = try JSONSerialization.jsonObject(with: data, options: .allowFragments) as? [AnyHashable: Any]
            value = Data()// info?[CodingKeys.value.rawValue] as AnyObject!
            expiryDate = info?[CodingKeys.expiryDate.rawValue] as! Date
        } catch {
            throw error
        }
        super.init()
    }
    
    required init() {
        super.init()
    }
    
    required init(realm: RLMRealm, schema: RLMObjectSchema) {
        super.init(realm: realm, schema: schema)
    }
    
    required init(value: Any, schema: RLMSchema) {
        super.init(value: value, schema: schema)
    }
    
    func setCacheValue(_ nvalue: CachableObject) {
        value = NSKeyedArchiver.archivedData(withRootObject: nvalue)
    }
    
    func getCacheValue() -> CachableObject? {
        guard value.count > 0 else { return nil }
        return NSKeyedUnarchiver.unarchiveObject(with: value) as? CachableObject
    }
}

extension Date {
    var isInThePast: Bool {
        return self.timeIntervalSinceNow < -60
    }
}

internal class InternalCacheObject: NSObject, CachableObject {
    var key: String = ""
    var value: Data = Data()
    var expiryDate: Date = Date()
    
    func isExpired() -> Bool {
        return expiryDate.isInThePast
    }
    
    func setCacheValue(_ nvalue: CachableObject) {
        value = NSKeyedArchiver.archivedData(withRootObject: nvalue)
    }
    
    func getCacheValue() -> CachableObject? {
        guard value.count > 0 else { return nil }
        return NSKeyedUnarchiver.unarchiveObject(with: value) as? CachableObject
    }
    
    init(key: String, value: Data, expiryDate: Date) {
        self.key = key
        self.value = value
        self.expiryDate = expiryDate
    }
    
    required init?(coder aDecoder: NSCoder) {
        guard let val = aDecoder.decodeObject(forKey: "value"),
            let expiry = aDecoder.decodeObject(forKey: "expiryDate") as? Date else {
                return nil
        }
        
        self.value = (val as? Data) ?? Data()
        self.expiryDate = expiry
        super.init()
    }
    
    func encode(with aCoder: NSCoder) {
        aCoder.encode(value, forKey: "value")
        aCoder.encode(expiryDate, forKey: "expiryDate")
    }
}

internal extension CacheObject {
    var internalCache: InternalCacheObject{
        return InternalCacheObject(key: key, value: value, expiryDate: expiryDate)
    }
}
