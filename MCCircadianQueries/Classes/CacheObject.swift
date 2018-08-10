import Realm
import RealmSwift

/// This class is a wrapper around an objects that should be cached to disk.
///
/// NOTE: It is currently not possible to use generics with a subclass of NSObject
/// 	 However, NSKeyedArchiver needs a concrete subclass of NSObject to work correctly
class CacheObject: Object, NSCoding {
    dynamic var key: String = ""
    dynamic var value: Data = Data()
    dynamic var expiryDate: Date = Date()
    
    override class func primaryKey() -> String? {
        return "key"
    }

    /// Designated initializer.
    ///
    /// - parameter value:      An object that should be cached
    /// - parameter expiryDate: The expiry date of the given value
    init(key: String = "", value: AnyObject, expiryDate: Date) {
        self.key = key
        self.value = value
        self.expiryDate = expiryDate
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

        self.value = val as AnyObject
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
            value = info?[CodingKeys.value.rawValue] as AnyObject!
            expiryDate = info?[CodingKeys.expiryDate.rawValue] as! Date
        } catch {
            throw error
        }
        super.init()
    }
    
    func setValue(_ nvalue: Any) {
        if let nvalue = try? JSONSerialization.data(withJSONObject: nvalue, options: .prettyPrinted) {
            value = nvalue
        }
    }
    
    func getValue() -> Any? {
        guard value.count > 0 else { return nil }
        return try? JSONSerialization.jsonObject(with: value, options: .allowFragments)
    }
}

extension Date {
    var isInThePast: Bool {
        return self.timeIntervalSinceNow < 0
    }
}
