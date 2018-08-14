import Foundation
import HealthKit
//import AwesomeCache

//let log = RemoteLog.sharedInstance

public enum MealType: String {
    case Empty     = ""
    case Breakfast = "Breakfast"
    case Lunch     = "Lunch"
    case Dinner    = "Dinner"
    case Snack     = "Snack"
}

public enum CircadianEvent: Equatable {
    case meal(mealType: MealType)
    case fast
    case sleep
    case exercise(exerciseType: HKWorkoutActivityType)

    public init?(value: String) {
        switch value[value.startIndex] {
        case "m":
            let mStr = value.substring(with: (value.characters.index(value.startIndex, offsetBy: 1) ..< value.endIndex))
            if let mt = MealType(rawValue: mStr) {
                self = .meal(mealType: mt)
            } else {
                return nil
            }

        case "f":
            self = .fast
        case "s":
            self = .sleep
        case "e":
            let eStr = value.substring(with: (value.characters.index(value.startIndex, offsetBy: 1) ..< value.endIndex))
            if let rawValue = UInt(eStr), let activityType = HKWorkoutActivityType(rawValue: rawValue) {
                self = .exercise(exerciseType: activityType)
            } else {
                return nil
            }

        default:
            return nil
        }
    }

    public func toString() -> String {
        switch self {
        case .meal(let mealType):
            return "m\(mealType)"
        case .fast:
            return "f"
        case .sleep:
            return "s"
        case .exercise(let exerciseType):
            return "e\(exerciseType.rawValue)"
        }
    }
}

public func ==(lhs: CircadianEvent, rhs: CircadianEvent) -> Bool {
    switch (lhs, rhs) {
    case (.meal(let a), .meal(let b)) where a == b: return true
    case (.exercise(let a), .exercise(let b)) where a == b: return true
    case (.fast, .fast): return true
    case (.sleep, .sleep): return true
    default: return false
    }
}

//@available(iOS 9.0, *)
open class MCCircadianEventArray: NSObject, CachableObject {
    open var events : [(Date, CircadianEvent)]

    init(events: [(Date, CircadianEvent)]) {
        self.events = events
        super.init()
    }

    required public convenience init?(coder aDecoder: NSCoder) {
        guard let dates = aDecoder.decodeObject(forKey: "dates") as? [Date] else { return nil }
        guard let strings = aDecoder.decodeObject(forKey: "events") as? [NSString] else { return nil }

        guard dates.count == strings.count else { return nil }

        self.init(events: dates.enumerated().flatMap {
            if let ce = CircadianEvent(value: strings[$0.0] as String) { return ($0.1, ce) }
            return nil
        })
    }

    open func encode(with aCoder: NSCoder) {
        aCoder.encode(events.map { return $0.0 }, forKey: "dates")
        aCoder.encode(events.map { return $0.1.toString() as NSString }, forKey: "events")
    }
    
    override init() {
        events = []
        super.init()
    }
}


/*
 * A protocol for unifying common metadata across HKSample and HKStatistic
 */
//@available(iOS 9.0, *)
public protocol MCSample {
    var startDate    : Date        { get }
    var endDate      : Date        { get }
    var numeralValue : Double?       { get }
    var hkType       : HKSampleType? { get }
}

//@available(iOS 9.0, *)
public struct MCStatisticSample : MCSample {
    public var statistic    : HKStatistics
    public var numeralValue : Double?

    public var startDate    : Date        { return statistic.startDate   }
    public var endDate      : Date        { return statistic.endDate     }
    public var hkType       : HKSampleType? { return statistic.hkType      }

    public init(statistic: HKStatistics, statsOption: HKStatisticsOptions) {
        self.statistic = statistic
        self.numeralValue = nil
        if ( statsOption.contains(.discreteAverage) ) {
            self.numeralValue = statistic.averageQuantity()?.doubleValue(for: hkType!.defaultUnit!)
        }
        if ( statsOption.contains(.discreteMin) ) {
            self.numeralValue = statistic.minimumQuantity()?.doubleValue(for: hkType!.defaultUnit!)
        }
        if ( statsOption.contains(.discreteMax) ) {
            self.numeralValue = statistic.maximumQuantity()?.doubleValue(for: hkType!.defaultUnit!)
        }
        if ( statsOption.contains(.cumulativeSum) ) {
            self.numeralValue = statistic.sumQuantity()?.doubleValue(for: hkType!.defaultUnit!)
        }
    }
}

public enum MCSampleCodingType: Int {
    case statisticsCoding
    case sampleCoding
    case aggregateCoding
    case rawCoding
}

open class MCSampleCoding: NSObject, NSCoding, MCSample {

    static let codingKey = "coding"

    static let statisticsKey = "statistics"
    static let sampleKey = "sample"
    static let aggregateKey = "aggregate"

    static let startKey = "start"
    static let endKey = "end"
    static let valKey = "value"
    static let typeKey = "type"

    open let coding: MCSampleCodingType

    open var statistic : HKStatistics?
    open var sample: HKSample?
    open var aggregate: MCAggregateSample.MCAggregateSampleCoding?

    open var startDate: Date
    open var endDate: Date
    open var numeralValue: Double?
    open var hkType: HKSampleType?

    public init(statistic: HKStatistics) {
        self.coding = .statisticsCoding
        self.statistic = statistic
        self.startDate = statistic.startDate
        self.endDate = statistic.endDate
    }

    public init(sample: HKSample) {
        self.coding = .sampleCoding
        self.sample = sample
        self.startDate = sample.startDate
        self.endDate = sample.endDate
    }

    public init(aggregate: MCAggregateSample) {
        self.coding = .aggregateCoding
        self.aggregate = MCAggregateSample.MCAggregateSampleCoding(aggregate: aggregate)
        self.startDate = aggregate.startDate
        self.endDate = aggregate.endDate
    }

    public init(start: Date, end: Date, value: Double?, hkType: HKSampleType?) {
        self.coding = .rawCoding
        self.startDate = start
        self.endDate = end
        self.numeralValue = value
        self.hkType = hkType
    }

    public convenience init(sample: MCSample) {
        switch sample {
        case is HKStatistics:
            self.init(statistic: sample as! HKStatistics)

        case is HKSample:
            self.init(sample: sample as! HKSample)

        case is MCAggregateSample:
            self.init(aggregate: sample as! MCAggregateSample)

        default:
            self.init(start: sample.startDate, end: sample.endDate, value: sample.numeralValue, hkType: sample.hkType)
        }
    }

    required public convenience init?(coder aDecoder: NSCoder) {
        let codingValue = aDecoder.decodeInteger(forKey: MCSampleCoding.codingKey)
        if let c = MCSampleCodingType(rawValue: codingValue) {
            switch c {
            case .statisticsCoding:
                guard let statistics = aDecoder.decodeObject(forKey: MCSampleCoding.statisticsKey) as? HKStatistics? else { return nil }
                self.init(statistic: statistics!)

            case .sampleCoding:
                guard let sample = aDecoder.decodeObject(forKey: MCSampleCoding.sampleKey) as? HKSample? else { return nil }
                self.init(sample: sample!)

            case .aggregateCoding:
                guard let aggregateCoding = aDecoder.decodeObject(forKey: MCSampleCoding.aggregateKey) as? MCAggregateSample.MCAggregateSampleCoding?, let aggregate = aggregateCoding?.aggregate else { return nil }
                self.init(aggregate: aggregate)

            case .rawCoding:
                guard let start = aDecoder.decodeObject(forKey: MCSampleCoding.startKey) as? Date else { return nil }
                guard let end = aDecoder.decodeObject(forKey: MCSampleCoding.endKey) as? Date else { return nil }
                guard let value = aDecoder.decodeObject(forKey: MCSampleCoding.valKey) as? Double? else { return nil }
                guard let hkType = aDecoder.decodeObject(forKey: MCSampleCoding.typeKey) as? HKSampleType? else { return nil }
                self.init(start: start, end: end, value: value, hkType: hkType)
            }
        } else {
            return nil
        }
    }

    open func encode(with aCoder: NSCoder) {
        aCoder.encode(coding.rawValue, forKey: MCSampleCoding.codingKey)
        switch coding {
        case .statisticsCoding:
            aCoder.encode(statistic, forKey: MCSampleCoding.statisticsKey)

        case .sampleCoding:
            aCoder.encode(sample, forKey: MCSampleCoding.sampleKey)

        case .aggregateCoding:
            aCoder.encode(aggregate, forKey: MCSampleCoding.aggregateKey)

        case .rawCoding:
            aCoder.encode(startDate, forKey: MCSampleCoding.startKey)
            aCoder.encode(endDate, forKey: MCSampleCoding.endKey)
            aCoder.encode(numeralValue, forKey: MCSampleCoding.valKey)
            aCoder.encode(hkType, forKey: MCSampleCoding.typeKey)
        }
    }

    open func toSample() -> MCSample {
        switch coding {
        case .statisticsCoding:
            return statistic!
        case .sampleCoding:
            return sample!
        case .aggregateCoding:
            return aggregate!.aggregate!
        case .rawCoding:
            return self
        }
    }
}

open class MCSampleArray: NSObject, CachableObject {
    static let countKey = "count"
    static let samplesKey = "samples"
    open var samples: [MCSample]

    public init(samples: [MCSample]) {
        self.samples = samples
        super.init()
    }

    required public convenience init?(coder aDecoder: NSCoder) {
        guard let codedSamples = aDecoder.decodeObject(forKey: MCSampleArray.samplesKey) as? [MCSampleCoding] else { return nil }
        self.init(samples: codedSamples.map { $0.toSample() })
    }

    open func encode(with aCoder: NSCoder) {
        aCoder.encode(samples.map { MCSampleCoding(sample: $0) }, forKey: MCSampleArray.samplesKey)
    }
    
    override init() {
        samples = []
        super.init()
    }
}


/*
 * Generalized aggregation, irrespective of HKSampleType.
 *
 * This relies on the numeralValue field provided by the MCSample protocol to provide
 * a valid numeric representation for all HKSampleTypes.
 *
 * The increment operation provided within can only be applied to samples of a matching type.
 */
//@available(iOS 9.0, *)
public struct MCAggregateSample : MCSample {
    public var startDate    : Date
    public var endDate      : Date
    public var numeralValue : Double?
    public var hkType       : HKSampleType?
    public var aggOp        : HKStatisticsOptions

    var runningAgg: [Double] = [0.0, 0.0, 0.0]
    var runningCnt: Int = 0

    public init(sample: MCSample, op: HKStatisticsOptions) {
        startDate = sample.startDate
        endDate = sample.endDate
        numeralValue = nil
        hkType = sample.hkType
        aggOp = op
        self.incr(sample)
    }

    public init(startDate: Date = Date(), endDate: Date = Date(), value: Double?, sampleType: HKSampleType?, op: HKStatisticsOptions) {
        self.startDate = startDate
        self.endDate = endDate
        numeralValue = value
        hkType = sampleType
        aggOp = op
    }

    public init(statistic: HKStatistics, op: HKStatisticsOptions) {
        startDate = statistic.startDate
        endDate = statistic.endDate
        numeralValue = statistic.numeralValue
        hkType = statistic.hkType
        aggOp = op

        // Initialize internal statistics.
        if let sumQ = statistic.sumQuantity() {
            runningAgg[0] = sumQ.doubleValue(for: hkType!.defaultUnit!)
        } else if let avgQ = statistic.averageQuantity() {
            runningAgg[0] = avgQ.doubleValue(for: hkType!.defaultUnit!)
            runningCnt = 1
        }
        if let minQ = statistic.minimumQuantity() {
            runningAgg[1] = minQ.doubleValue(for: hkType!.defaultUnit!)
        }
        if let maxQ = statistic.maximumQuantity() {
            runningAgg[2] = maxQ.doubleValue(for: hkType!.defaultUnit!)
        }
    }

    public init(startDate: Date, endDate: Date, numeralValue: Double?, hkType: HKSampleType?,
                aggOp: HKStatisticsOptions, runningAgg: [Double], runningCnt: Int)
    {
        self.startDate = startDate
        self.endDate = endDate
        self.numeralValue = numeralValue
        self.hkType = hkType
        self.aggOp = aggOp
        self.runningAgg = runningAgg
        self.runningCnt = runningCnt
    }
    
    public mutating func rsum(_ sample: MCSample) {
        //        print("value for sample \(sample)")
        if let amount = sample.numeralValue {   runningAgg[0] += amount
            runningCnt += 1 }
    }

    public mutating func rmin(_ sample: MCSample) {
        if let amount = sample.numeralValue { runningAgg[1] = min(runningAgg[1], amount)
            runningCnt += 1 }
    }

    public mutating func rmax(_ sample: MCSample) {
        if let amount = sample.numeralValue {runningAgg[2] = max(runningAgg[2], amount)
            runningCnt += 1 }
    }

    public mutating func incrOp(_ sample: MCSample) {
        if aggOp.contains(.discreteAverage) || aggOp.contains(.cumulativeSum) {
            rsum(sample)
        }
        if aggOp.contains(.discreteMin) {
            rmin(sample)
        }
        if aggOp.contains(.discreteMax) {
            rmax(sample)
        }
    }

    public mutating func incr(_ sample: MCSample) {
        if hkType == sample.hkType {
            startDate = min(sample.startDate, startDate)
            endDate = max(sample.endDate, endDate)

            switch hkType! {
            case is HKCategoryType:
                switch hkType!.identifier {
                case HKCategoryTypeIdentifier.sleepAnalysis.rawValue:
                    incrOp(sample)

                default: break
//                    log.error("Cannot aggregate \(hkType)")
                }

            case is HKCorrelationType:
                switch hkType!.identifier {
                case HKCorrelationTypeIdentifier.bloodPressure.rawValue:
                    incrOp(sample)

                default: break
//                    log.error("Cannot aggregate \(hkType)")
                }

            case is HKWorkoutType:
                incrOp(sample)

            case is HKQuantityType:
                incrOp(sample)

            default: break
//                log.error("Cannot aggregate \(hkType)")
            }

        } else {
//            log.error("Invalid sample aggregation between \(hkType) and \(sample.hkType)")
        }
    }

    public mutating func final() {
        if aggOp.contains(.cumulativeSum) {
            numeralValue = runningAgg[0]
        } else if aggOp.contains(.discreteAverage) {
            numeralValue = runningAgg[0] / Double(runningCnt)
        } else if aggOp.contains(.discreteMin) {
            numeralValue = runningAgg[1]
        } else if aggOp.contains(.discreteMax) {
            numeralValue = runningAgg[2]
        }
    }

    public mutating func finalAggregate(_ finalOp: HKStatisticsOptions) {
        if aggOp.contains(.cumulativeSum) && finalOp.contains(.cumulativeSum) {
            numeralValue = runningAgg[0]
        } else if aggOp.contains(.discreteAverage) && finalOp.contains(.discreteAverage) {
            numeralValue = runningAgg[0] / Double(runningCnt)
        } else if aggOp.contains(.discreteMin) && finalOp.contains(.discreteMin) {
            numeralValue = runningAgg[1]
        } else if aggOp.contains(.discreteMax) && finalOp.contains(.discreteMax) {
            numeralValue = runningAgg[2]
        }
    }

    public func query(_ stats: HKStatisticsOptions) -> Double? {
        if ( stats.contains(.cumulativeSum) && aggOp.contains(.cumulativeSum) ) {
            return runningAgg[0]
        }
        if ( stats.contains(.discreteAverage) && aggOp.contains(.discreteAverage) ) {
            return runningAgg[0] / Double(runningCnt)
        }
        if ( stats.contains(.discreteMin) && aggOp.contains(.discreteMin) ) {
            return runningAgg[1]
        }
        if ( stats.contains(.discreteMax) && aggOp.contains(.discreteMax) ) {
            return runningAgg[2]
        }
        return nil
    }

    public func count() -> Int { return runningCnt }

    // Encoding/decoding.
    public static func encode(_ aggregate: MCAggregateSample) -> MCAggregateSampleCoding {
        return MCAggregateSampleCoding(aggregate: aggregate)
    }

    public static func decode(_ aggregateEncoding: MCAggregateSampleCoding) -> MCAggregateSample? {
        return aggregateEncoding.aggregate
    }
}

//@available(iOS 9.0, *)
public extension MCAggregateSample {
    @objc(_TtCV18MCCircadianQueries17MCAggregateSample23MCAggregateSampleCoding) public class MCAggregateSampleCoding: NSObject, NSCoding {

        var aggregate: MCAggregateSample?

        init(aggregate: MCAggregateSample) {
            self.aggregate = aggregate
            super.init()
        }

        required public init?(coder aDecoder: NSCoder) {
            guard let startDate    = aDecoder.decodeObject(forKey: "startDate")    as? Date         else { print("Failed to rebuild MCAggregateSample startDate"); aggregate = nil; super.init(); return nil }
            guard let endDate      = aDecoder.decodeObject(forKey: "endDate")      as? Date         else { print("Failed to rebuild MCAggregateSample endDate"); aggregate = nil; super.init(); return nil }
            guard let numeralValue = aDecoder.decodeObject(forKey: "numeralValue") as? Double?        else { print("Failed to rebuild MCAggregateSample numeralValue"); aggregate = nil; super.init(); return nil }
            guard let hkType       = aDecoder.decodeObject(forKey: "hkType")       as? HKSampleType?  else { print("Failed to rebuild MCAggregateSample hkType"); aggregate = nil; super.init(); return nil }
            guard let runningAgg   = aDecoder.decodeObject(forKey: "runningAgg")   as? [Double]       else { print("Failed to rebuild MCAggregateSample runningAgg"); aggregate = nil; super.init(); return nil }
            
            let runningCnt = aDecoder.decodeInteger(forKey: "runningCnt")
            let aggOp      = UInt(aDecoder.decodeInteger(forKey: "aggOp"))
            
            aggregate = MCAggregateSample(startDate: startDate, endDate: endDate, numeralValue: numeralValue, hkType: hkType,
                                          aggOp: HKStatisticsOptions(rawValue: aggOp), runningAgg: runningAgg, runningCnt: runningCnt)
//            print("aggregate is: \(String(describing: aggregate)))")
            
            super.init()
        }
        
        open func encode(with aCoder: NSCoder) {
            aCoder.encode(aggregate!.startDate,      forKey: "startDate")
            aCoder.encode(aggregate!.endDate,        forKey: "endDate")
            aCoder.encode(aggregate!.numeralValue,   forKey: "numeralValue")
            aCoder.encode(aggregate!.hkType,         forKey: "hkType")
            aCoder.encode(Int(aggregate!.aggOp.rawValue), forKey: "aggOp")
            aCoder.encode(aggregate!.runningAgg,     forKey: "runningAgg")
            aCoder.encode(aggregate!.runningCnt,     forKey: "runningCnt")
        }
    }
}

//@available(iOS 9.0, *)
public class MCAggregateArray: NSObject, CachableObject {
    open var aggregates : [MCAggregateSample]

    init(aggregates: [MCAggregateSample]) {
        self.aggregates = aggregates
        super.init()
    }

    required public convenience init?(coder aDecoder: NSCoder) {
        guard let aggs = aDecoder.decodeObject(forKey: "aggregates") as? [MCAggregateSample.MCAggregateSampleCoding] else { return nil }
        self.init(aggregates: aggs.flatMap({ return MCAggregateSample.decode($0) }))
    }

    open func encode(with aCoder: NSCoder) {
        aCoder.encode(aggregates.map { return MCAggregateSample.encode($0) }, forKey: "aggregates")
    }
    
    override init() {
        aggregates = []
        super.init()
    }
}


// MARK: - Categories & Extensions

// Default aggregation for all subtypes of HKSampleType.

//@available(iOS 9.0, *)
public extension HKSampleType {
    var aggregationOptions: HKStatisticsOptions {
        switch self {
        case is HKCategoryType:
            return .discreteAverage

        case is HKCorrelationType:
            return .discreteAverage

        case is HKWorkoutType:
            return .cumulativeSum

        case is HKQuantityType:
            let quantity = self as! HKQuantityType
            switch quantity.aggregationStyle {
            case .discrete:
                return .discreteAverage
            case .cumulative:
                return .cumulativeSum
            }

        default:
            fatalError("Invalid aggregation overy \(self.identifier)")
        }
    }
}

// Duration aggregate for HKSample arrays.
public extension Array where Element: HKSample {
    public var sleepDuration: TimeInterval? {
        return filter { (sample) -> Bool in
            let categorySample = sample as! HKCategorySample
            return categorySample.sampleType.identifier == HKCategoryTypeIdentifier.sleepAnalysis.rawValue
                && categorySample.value == HKCategoryValueSleepAnalysis.asleep.rawValue
            }.map { (sample) -> TimeInterval in
                return sample.endDate.timeIntervalSince(sample.startDate)
            }.reduce(0) { $0 + $1 }
    }

    public var workoutDuration: TimeInterval? {
        return filter { (sample) -> Bool in
            let categorySample = sample as! HKWorkout
            return categorySample.sampleType.identifier == HKWorkoutTypeIdentifier
            }.map { (sample) -> TimeInterval in
                return sample.endDate.timeIntervalSince(sample.startDate)
            }.reduce(0) { $0 + $1 }
    }
}

/*
 * MCSample extensions for HKStatistics.
 */
extension HKStatistics: MCSample { }

//@available(iOS 9.0, *)
public extension HKStatistics {
    var quantity: HKQuantity? {
        switch quantityType.aggregationStyle {
        case .discrete:
            return averageQuantity()
        case .cumulative:
            return sumQuantity()
        }
    }

    public var numeralValue: Double? {
        guard hkType?.defaultUnit != nil && quantity.self != nil else {
            return nil
        }
        return quantity!.doubleValue(for: hkType!.defaultUnit!)
    }

    public var hkType: HKSampleType? { return quantityType }
}

/*
 * MCSample extensions for HKSample.
 */

extension HKSample: MCSample { }

@available(iOS 9.0, *)
public extension HKSampleType {

    public func unitForSystem(_ metric: Bool) -> HKUnit? {
        switch identifier {
        case HKCategoryTypeIdentifier.sleepAnalysis.rawValue:
            return HKUnit.hour()

        case HKCategoryTypeIdentifier.appleStandHour.rawValue:
            return HKUnit.hour()

        case HKCorrelationTypeIdentifier.bloodPressure.rawValue:
            return HKUnit.millimeterOfMercury()

        case HKQuantityTypeIdentifier.activeEnergyBurned.rawValue:
            return HKUnit.kilocalorie()

        case HKQuantityTypeIdentifier.basalBodyTemperature.rawValue:
            return HKUnit.degreeFahrenheit()

        case HKQuantityTypeIdentifier.basalEnergyBurned.rawValue:
            return HKUnit.kilocalorie()

        case HKQuantityTypeIdentifier.bloodAlcoholContent.rawValue:
            return HKUnit.percent()

        case HKQuantityTypeIdentifier.bloodGlucose.rawValue:
            return HKUnit.gramUnit(with: .milli).unitDivided(by: HKUnit.literUnit(with: .deci))

        case HKQuantityTypeIdentifier.bloodPressureDiastolic.rawValue:
            return HKUnit.millimeterOfMercury()

        case HKQuantityTypeIdentifier.bloodPressureSystolic.rawValue:
            return HKUnit.millimeterOfMercury()

        case HKQuantityTypeIdentifier.bodyFatPercentage.rawValue:
            return HKUnit.percent()

        case HKQuantityTypeIdentifier.bodyMass.rawValue:
            return metric ? HKUnit.gramUnit(with: .kilo) : HKUnit.pound()

        case HKQuantityTypeIdentifier.bodyMassIndex.rawValue:
            return HKUnit.count()

        case HKQuantityTypeIdentifier.bodyTemperature.rawValue:
            return HKUnit.degreeFahrenheit()

        case HKQuantityTypeIdentifier.dietaryBiotin.rawValue:
            return HKUnit.gramUnit(with: HKMetricPrefix.micro)

        case HKQuantityTypeIdentifier.dietaryCaffeine.rawValue:
            return HKUnit.gramUnit(with: HKMetricPrefix.milli)

        case HKQuantityTypeIdentifier.dietaryCalcium.rawValue:
            return HKUnit.gramUnit(with: HKMetricPrefix.milli)

        case HKQuantityTypeIdentifier.dietaryCarbohydrates.rawValue:
            return HKUnit.gram()

        case HKQuantityTypeIdentifier.dietaryCholesterol.rawValue:
            return HKUnit.gramUnit(with: HKMetricPrefix.milli)

        case HKQuantityTypeIdentifier.dietaryChloride.rawValue:
            return HKUnit.gramUnit(with: HKMetricPrefix.milli)

        case HKQuantityTypeIdentifier.dietaryChromium.rawValue:
            return HKUnit.gramUnit(with: HKMetricPrefix.micro)

        case HKQuantityTypeIdentifier.dietaryCopper.rawValue:
            return HKUnit.gramUnit(with: HKMetricPrefix.milli)

        case HKQuantityTypeIdentifier.dietaryEnergyConsumed.rawValue:
            return HKUnit.kilocalorie()

        case HKQuantityTypeIdentifier.dietaryFatMonounsaturated.rawValue:
            return HKUnit.gram()

        case HKQuantityTypeIdentifier.dietaryFatPolyunsaturated.rawValue:
            return HKUnit.gram()

        case HKQuantityTypeIdentifier.dietaryFatSaturated.rawValue:
            return HKUnit.gram()

        case HKQuantityTypeIdentifier.dietaryFatTotal.rawValue:
            return HKUnit.gram()

        case HKQuantityTypeIdentifier.dietaryFiber.rawValue:
            return HKUnit.gram()

        case HKQuantityTypeIdentifier.dietaryFolate.rawValue:
            return HKUnit.gramUnit(with: HKMetricPrefix.micro)

        case HKQuantityTypeIdentifier.dietaryIodine.rawValue:
            return HKUnit.gramUnit(with: HKMetricPrefix.micro)

        case HKQuantityTypeIdentifier.dietaryIron.rawValue:
            return HKUnit.gramUnit(with: HKMetricPrefix.milli)

        case HKQuantityTypeIdentifier.dietaryMagnesium.rawValue:
            return HKUnit.gramUnit(with: HKMetricPrefix.milli)

        case HKQuantityTypeIdentifier.dietaryManganese.rawValue:
            return HKUnit.gramUnit(with: HKMetricPrefix.milli)

        case HKQuantityTypeIdentifier.dietaryMolybdenum.rawValue:
            return HKUnit.gramUnit(with: HKMetricPrefix.micro)

        case HKQuantityTypeIdentifier.dietaryNiacin.rawValue:
            return HKUnit.gramUnit(with: HKMetricPrefix.milli)

        case HKQuantityTypeIdentifier.dietaryPantothenicAcid.rawValue:
            return HKUnit.gramUnit(with: HKMetricPrefix.milli)

        case HKQuantityTypeIdentifier.dietaryPhosphorus.rawValue:
            return HKUnit.gramUnit(with: HKMetricPrefix.milli)

        case HKQuantityTypeIdentifier.dietaryPotassium.rawValue:
            return HKUnit.gramUnit(with: HKMetricPrefix.milli)

        case HKQuantityTypeIdentifier.dietaryProtein.rawValue:
            return HKUnit.gram()

        case HKQuantityTypeIdentifier.dietaryRiboflavin.rawValue:
            return HKUnit.gramUnit(with: HKMetricPrefix.milli)

        case HKQuantityTypeIdentifier.dietarySelenium.rawValue:
            return HKUnit.gramUnit(with: HKMetricPrefix.micro)

        case HKQuantityTypeIdentifier.dietarySodium.rawValue:
            return HKUnit.gramUnit(with: HKMetricPrefix.milli)

        case HKQuantityTypeIdentifier.dietarySugar.rawValue:
            return HKUnit.gram()

        case HKQuantityTypeIdentifier.dietaryThiamin.rawValue:
            return HKUnit.gramUnit(with: HKMetricPrefix.milli)

        case HKQuantityTypeIdentifier.dietaryVitaminA.rawValue:
            return HKUnit.gramUnit(with: HKMetricPrefix.micro)

        case HKQuantityTypeIdentifier.dietaryVitaminB12.rawValue:
            return HKUnit.gramUnit(with: HKMetricPrefix.micro)

        case HKQuantityTypeIdentifier.dietaryVitaminB6.rawValue:
            return HKUnit.gramUnit(with: HKMetricPrefix.milli)

        case HKQuantityTypeIdentifier.dietaryVitaminC.rawValue:
            return HKUnit.gramUnit(with: HKMetricPrefix.milli)

        case HKQuantityTypeIdentifier.dietaryVitaminD.rawValue:
            return HKUnit.gramUnit(with: HKMetricPrefix.micro)

        case HKQuantityTypeIdentifier.dietaryVitaminE.rawValue:
            return HKUnit.gramUnit(with: HKMetricPrefix.milli)

        case HKQuantityTypeIdentifier.dietaryVitaminK.rawValue:
            return HKUnit.gramUnit(with: HKMetricPrefix.micro)

        case HKQuantityTypeIdentifier.dietaryWater.rawValue:
            return HKUnit.literUnit(with: HKMetricPrefix.milli)

        case HKQuantityTypeIdentifier.dietaryZinc.rawValue:
            return HKUnit.gramUnit(with: HKMetricPrefix.milli)

        case HKQuantityTypeIdentifier.distanceWalkingRunning.rawValue:
            return metric ? HKUnit.meterUnit(with: HKMetricPrefix.kilo) : HKUnit.mile()

        case HKQuantityTypeIdentifier.electrodermalActivity.rawValue:
            return HKUnit.siemenUnit(with: HKMetricPrefix.micro)

        case HKQuantityTypeIdentifier.flightsClimbed.rawValue:
            return HKUnit.count()

        case HKQuantityTypeIdentifier.forcedExpiratoryVolume1.rawValue:
            return HKUnit.liter()

        case HKQuantityTypeIdentifier.forcedVitalCapacity.rawValue:
            return HKUnit.liter()

        case HKQuantityTypeIdentifier.height.rawValue:
            return metric ? HKUnit.meterUnit(with: HKMetricPrefix.centi) : HKUnit.foot()

        case HKQuantityTypeIdentifier.inhalerUsage.rawValue:
            return HKUnit.count()

        case HKQuantityTypeIdentifier.leanBodyMass.rawValue:
            return metric ? HKUnit.gramUnit(with: .kilo) : HKUnit.pound()

        case HKQuantityTypeIdentifier.heartRate.rawValue:
            return HKUnit.count().unitDivided(by: HKUnit.minute())

        case HKQuantityTypeIdentifier.nikeFuel.rawValue:
            return HKUnit.count()

        case HKQuantityTypeIdentifier.numberOfTimesFallen.rawValue:
            return HKUnit.count()

        case HKQuantityTypeIdentifier.oxygenSaturation.rawValue:
            return HKUnit.percent()
            
        case HKQuantityTypeIdentifier.peakExpiratoryFlowRate.rawValue:
            return HKUnit.liter().unitDivided(by: HKUnit.minute())
            
        case HKQuantityTypeIdentifier.peripheralPerfusionIndex.rawValue:
            return HKUnit.percent()
            
        case HKQuantityTypeIdentifier.respiratoryRate.rawValue:
            return HKUnit.count().unitDivided(by: HKUnit.minute())
            
        case HKQuantityTypeIdentifier.stepCount.rawValue:
            return HKUnit.count()
            
        case HKQuantityTypeIdentifier.uvExposure.rawValue:
            return HKUnit.count()
            
        case HKWorkoutTypeIdentifier:
            return HKUnit.hour()
            
        default:
            return nil
        }
    }

    public var defaultUnit: HKUnit? {
        return unitForSystem(true)
    }

    // Units used by the MC webservice.
    public var serviceUnit: HKUnit? {
        switch identifier {
        case HKCategoryTypeIdentifier.sleepAnalysis.rawValue:
            return HKUnit.second()

        case HKCategoryTypeIdentifier.appleStandHour.rawValue:
            return HKUnit.second()

        case HKCorrelationTypeIdentifier.bloodPressure.rawValue:
            return HKUnit.millimeterOfMercury()

        case HKQuantityTypeIdentifier.activeEnergyBurned.rawValue:
            return HKUnit.kilocalorie()

        case HKQuantityTypeIdentifier.basalBodyTemperature.rawValue:
            return HKUnit.degreeFahrenheit()

        case HKQuantityTypeIdentifier.basalEnergyBurned.rawValue:
            return HKUnit.kilocalorie()

        case HKQuantityTypeIdentifier.bloodAlcoholContent.rawValue:
            return HKUnit.percent()

        case HKQuantityTypeIdentifier.bloodGlucose.rawValue:
            return HKUnit.gramUnit(with: .milli).unitDivided(by: HKUnit.literUnit(with: .deci))

        case HKQuantityTypeIdentifier.bloodPressureDiastolic.rawValue:
            return HKUnit.millimeterOfMercury()

        case HKQuantityTypeIdentifier.bloodPressureSystolic.rawValue:
            return HKUnit.millimeterOfMercury()

        case HKQuantityTypeIdentifier.bodyFatPercentage.rawValue:
            return HKUnit.percent()

        case HKQuantityTypeIdentifier.bodyMass.rawValue:
            return HKUnit.gramUnit(with: .kilo)

        case HKQuantityTypeIdentifier.bodyMassIndex.rawValue:
            return HKUnit.count()

        case HKQuantityTypeIdentifier.bodyTemperature.rawValue:
            return HKUnit.degreeFahrenheit()

        case HKQuantityTypeIdentifier.dietaryBiotin.rawValue:
            return HKUnit.gramUnit(with: HKMetricPrefix.micro)

        case HKQuantityTypeIdentifier.dietaryCaffeine.rawValue:
            return HKUnit.gramUnit(with: HKMetricPrefix.milli)

        case HKQuantityTypeIdentifier.dietaryCalcium.rawValue:
            return HKUnit.gramUnit(with: HKMetricPrefix.milli)

        case HKQuantityTypeIdentifier.dietaryCarbohydrates.rawValue:
            return HKUnit.gram()

        case HKQuantityTypeIdentifier.dietaryCholesterol.rawValue:
            return HKUnit.gramUnit(with: HKMetricPrefix.milli)

        case HKQuantityTypeIdentifier.dietaryChloride.rawValue:
            return HKUnit.gramUnit(with: HKMetricPrefix.milli)

        case HKQuantityTypeIdentifier.dietaryChromium.rawValue:
            return HKUnit.gramUnit(with: HKMetricPrefix.micro)

        case HKQuantityTypeIdentifier.dietaryCopper.rawValue:
            return HKUnit.gramUnit(with: HKMetricPrefix.milli)

        case HKQuantityTypeIdentifier.dietaryEnergyConsumed.rawValue:
            return HKUnit.kilocalorie()

        case HKQuantityTypeIdentifier.dietaryFatMonounsaturated.rawValue:
            return HKUnit.gram()

        case HKQuantityTypeIdentifier.dietaryFatPolyunsaturated.rawValue:
            return HKUnit.gram()

        case HKQuantityTypeIdentifier.dietaryFatSaturated.rawValue:
            return HKUnit.gram()

        case HKQuantityTypeIdentifier.dietaryFatTotal.rawValue:
            return HKUnit.gram()

        case HKQuantityTypeIdentifier.dietaryFiber.rawValue:
            return HKUnit.gram()

        case HKQuantityTypeIdentifier.dietaryFolate.rawValue:
            return HKUnit.gramUnit(with: HKMetricPrefix.micro)

        case HKQuantityTypeIdentifier.dietaryIodine.rawValue:
            return HKUnit.gramUnit(with: HKMetricPrefix.micro)

        case HKQuantityTypeIdentifier.dietaryIron.rawValue:
            return HKUnit.gramUnit(with: HKMetricPrefix.milli)

        case HKQuantityTypeIdentifier.dietaryMagnesium.rawValue:
            return HKUnit.gramUnit(with: HKMetricPrefix.milli)

        case HKQuantityTypeIdentifier.dietaryManganese.rawValue:
            return HKUnit.gramUnit(with: HKMetricPrefix.milli)

        case HKQuantityTypeIdentifier.dietaryMolybdenum.rawValue:
            return HKUnit.gramUnit(with: HKMetricPrefix.micro)

        case HKQuantityTypeIdentifier.dietaryNiacin.rawValue:
            return HKUnit.gramUnit(with: HKMetricPrefix.milli)

        case HKQuantityTypeIdentifier.dietaryPantothenicAcid.rawValue:
            return HKUnit.gramUnit(with: HKMetricPrefix.milli)

        case HKQuantityTypeIdentifier.dietaryPhosphorus.rawValue:
            return HKUnit.gramUnit(with: HKMetricPrefix.milli)

        case HKQuantityTypeIdentifier.dietaryPotassium.rawValue:
            return HKUnit.gramUnit(with: HKMetricPrefix.milli)

        case HKQuantityTypeIdentifier.dietaryProtein.rawValue:
            return HKUnit.gram()

        case HKQuantityTypeIdentifier.dietaryRiboflavin.rawValue:
            return HKUnit.gramUnit(with: HKMetricPrefix.milli)

        case HKQuantityTypeIdentifier.dietarySelenium.rawValue:
            return HKUnit.gramUnit(with: HKMetricPrefix.micro)

        case HKQuantityTypeIdentifier.dietarySodium.rawValue:
            return HKUnit.gramUnit(with: HKMetricPrefix.milli)

        case HKQuantityTypeIdentifier.dietarySugar.rawValue:
            return HKUnit.gram()

        case HKQuantityTypeIdentifier.dietaryThiamin.rawValue:
            return HKUnit.gramUnit(with: HKMetricPrefix.milli)

        case HKQuantityTypeIdentifier.dietaryVitaminA.rawValue:
            return HKUnit.gramUnit(with: HKMetricPrefix.micro)

        case HKQuantityTypeIdentifier.dietaryVitaminB12.rawValue:
            return HKUnit.gramUnit(with: HKMetricPrefix.micro)

        case HKQuantityTypeIdentifier.dietaryVitaminB6.rawValue:
            return HKUnit.gramUnit(with: HKMetricPrefix.milli)

        case HKQuantityTypeIdentifier.dietaryVitaminC.rawValue:
            return HKUnit.gramUnit(with: HKMetricPrefix.milli)

        case HKQuantityTypeIdentifier.dietaryVitaminD.rawValue:
            return HKUnit.gramUnit(with: HKMetricPrefix.micro)

        case HKQuantityTypeIdentifier.dietaryVitaminE.rawValue:
            return HKUnit.gramUnit(with: HKMetricPrefix.milli)

        case HKQuantityTypeIdentifier.dietaryVitaminK.rawValue:
            return HKUnit.gramUnit(with: HKMetricPrefix.micro)

        case HKQuantityTypeIdentifier.dietaryWater.rawValue:
            return HKUnit.literUnit(with: HKMetricPrefix.milli)

        case HKQuantityTypeIdentifier.dietaryZinc.rawValue:
            return HKUnit.gramUnit(with: HKMetricPrefix.milli)

        case HKQuantityTypeIdentifier.distanceWalkingRunning.rawValue:
            return HKUnit.meter()

        case HKQuantityTypeIdentifier.electrodermalActivity.rawValue:
            return HKUnit.siemenUnit(with: HKMetricPrefix.micro)

        case HKQuantityTypeIdentifier.flightsClimbed.rawValue:
            return HKUnit.count()

        case HKQuantityTypeIdentifier.forcedExpiratoryVolume1.rawValue:
            return HKUnit.literUnit(with: HKMetricPrefix.milli)

        case HKQuantityTypeIdentifier.forcedVitalCapacity.rawValue:
            return HKUnit.literUnit(with: HKMetricPrefix.milli)

        case HKQuantityTypeIdentifier.height.rawValue:
            return HKUnit.meterUnit(with: HKMetricPrefix.centi)

        case HKQuantityTypeIdentifier.inhalerUsage.rawValue:
            return HKUnit.count()

        case HKQuantityTypeIdentifier.leanBodyMass.rawValue:
            return HKUnit.gramUnit(with: .kilo)

        case HKQuantityTypeIdentifier.heartRate.rawValue:
            return HKUnit.count().unitDivided(by: HKUnit.minute())

        case HKQuantityTypeIdentifier.nikeFuel.rawValue:
            return HKUnit.count()

        case HKQuantityTypeIdentifier.numberOfTimesFallen.rawValue:
            return HKUnit.count()

        case HKQuantityTypeIdentifier.oxygenSaturation.rawValue:
            return HKUnit.percent()
            
        case HKQuantityTypeIdentifier.peakExpiratoryFlowRate.rawValue:
            return HKUnit.liter().unitDivided(by: HKUnit.minute())
            
        case HKQuantityTypeIdentifier.peripheralPerfusionIndex.rawValue:
            return HKUnit.percent()
            
        case HKQuantityTypeIdentifier.respiratoryRate.rawValue:
            return HKUnit.count().unitDivided(by: HKUnit.minute())
            
        case HKQuantityTypeIdentifier.stepCount.rawValue:
            return HKUnit.count()
            
        case HKQuantityTypeIdentifier.uvExposure.rawValue:
            return HKUnit.count()
            
        case HKWorkoutTypeIdentifier:
            return HKUnit.second()
            
        default:
            return nil
        }
    }
}

//@available(iOS 9.0, *)
public extension HKSample {
    public var numeralValue: Double? {
        guard hkType?.defaultUnit != nil else {
            return nil
        }
        switch HKSampleType.self {
        case is HKCategoryType:
            switch sampleType.identifier {
            case HKCategoryTypeIdentifier.sleepAnalysis.rawValue:
                let sample = (self as! HKCategorySample)
                let secs = HKQuantity(unit: HKUnit.second(), doubleValue: sample.endDate.timeIntervalSince(sample.startDate))
                return secs.doubleValue(for: hkType!.defaultUnit!)
            default:
                return nil
            }

        case is HKCorrelationType:
            switch sampleType.identifier {
            case HKCorrelationTypeIdentifier.bloodPressure.rawValue:
                return ((self as! HKCorrelation).objects.first as! HKQuantitySample).quantity.doubleValue(for: hkType!.defaultUnit!)
            default:
                return nil
            }

        case is HKWorkoutType:
            let sample = (self as! HKWorkout)
            let secs = HKQuantity(unit: HKUnit.second(), doubleValue: sample.duration)
            return secs.doubleValue(for: hkType!.defaultUnit!)

        case is HKQuantityType:
            return (self as! HKQuantitySample).quantity.doubleValue(for: hkType!.defaultUnit!)

        default:
            return nil
        }
    }

    public var hkType: HKSampleType? { return sampleType }
}

// Readable type description.
//@available(iOS 9.0, *)
public extension HKSampleType {
    public var displayText: String? {
        switch identifier {
        case HKCategoryTypeIdentifier.sleepAnalysis.rawValue:
            return NSLocalizedString("Sleep", comment: "HealthKit data type")

        case HKCategoryTypeIdentifier.appleStandHour.rawValue:
            return NSLocalizedString("Hours Standing", comment: "HealthKit data type")

        case HKCharacteristicTypeIdentifier.bloodType.rawValue:
            return NSLocalizedString("Blood Type", comment: "HealthKit data type")

        case HKCharacteristicTypeIdentifier.biologicalSex.rawValue:
            return NSLocalizedString("Gender", comment: "HealthKit data type")

        case HKCharacteristicTypeIdentifier.fitzpatrickSkinType.rawValue:
            return NSLocalizedString("Skin Type", comment: "HealthKit data type")

        case HKCorrelationTypeIdentifier.bloodPressure.rawValue:
            return NSLocalizedString("Blood Pressure", comment: "HealthKit data type")

        case HKQuantityTypeIdentifier.activeEnergyBurned.rawValue:
            return NSLocalizedString("Active Energy Burned", comment: "HealthKit data type")

        case HKQuantityTypeIdentifier.basalEnergyBurned.rawValue:
            return NSLocalizedString("Basal Energy Burned", comment: "HealthKit data type")

        case HKQuantityTypeIdentifier.bloodGlucose.rawValue:
            return NSLocalizedString("Blood Glucose", comment: "HealthKit data type")

        case HKQuantityTypeIdentifier.bloodPressureDiastolic.rawValue:
            return NSLocalizedString("Blood Pressure Diastolic", comment: "HealthKit data type")

        case HKQuantityTypeIdentifier.bloodPressureSystolic.rawValue:
            return NSLocalizedString("Blood Pressure Systolic", comment: "HealthKit data type")

        case HKQuantityTypeIdentifier.bodyMass.rawValue:
            return NSLocalizedString("Weight", comment: "HealthKit data type")

        case HKQuantityTypeIdentifier.bodyMassIndex.rawValue:
            return NSLocalizedString("Body Mass Index", comment: "HealthKit data type")

        case HKQuantityTypeIdentifier.dietaryCaffeine.rawValue:
            return NSLocalizedString("Caffeine", comment: "HealthKit data type")

        case HKQuantityTypeIdentifier.dietaryCarbohydrates.rawValue:
            return NSLocalizedString("Carbohydrates", comment: "HealthKit data type")

        case HKQuantityTypeIdentifier.dietaryCholesterol.rawValue:
            return NSLocalizedString("Cholesterol", comment: "HealthKit data type")

        case HKQuantityTypeIdentifier.dietaryEnergyConsumed.rawValue:
            return NSLocalizedString("Food calories", comment: "HealthKit data type")

        case HKQuantityTypeIdentifier.dietaryFatMonounsaturated.rawValue:
            return NSLocalizedString("Monounsaturated Fat", comment: "HealthKit data type")

        case HKQuantityTypeIdentifier.dietaryFatPolyunsaturated.rawValue:
            return NSLocalizedString("Polyunsaturated Fat", comment: "HealthKit data type")

        case HKQuantityTypeIdentifier.dietaryFatSaturated.rawValue:
            return NSLocalizedString("Saturated Fat", comment: "HealthKit data type")

        case HKQuantityTypeIdentifier.dietaryFatTotal.rawValue:
            return NSLocalizedString("Fat", comment: "HealthKit data type")

        case HKQuantityTypeIdentifier.dietaryProtein.rawValue:
            return NSLocalizedString("Protein", comment: "HealthKit data type")

        case HKQuantityTypeIdentifier.dietarySodium.rawValue:
            return NSLocalizedString("Salt", comment: "HealthKit data type")

        case HKQuantityTypeIdentifier.dietarySugar.rawValue:
            return NSLocalizedString("Sugar", comment: "HealthKit data type")

        case HKQuantityTypeIdentifier.dietaryWater.rawValue:
            return NSLocalizedString("Water", comment: "HealthKit data type")

        case HKQuantityTypeIdentifier.distanceWalkingRunning.rawValue:
            return NSLocalizedString("Walking and Running Distance", comment: "HealthKit data type")

        case HKQuantityTypeIdentifier.flightsClimbed.rawValue:
            return NSLocalizedString("Flights Climbed", comment: "HealthKit data type")

        case HKQuantityTypeIdentifier.heartRate.rawValue:
            return NSLocalizedString("Heart Rate", comment: "HealthKit data type")

        case HKQuantityTypeIdentifier.stepCount.rawValue:
            return NSLocalizedString("Step Count", comment: "HealthKit data type")

        case HKQuantityTypeIdentifier.uvExposure.rawValue:
            return NSLocalizedString("UV Exposure", comment: "HealthKit data type")

        case HKWorkoutTypeIdentifier:
            return NSLocalizedString("Workouts/Meals", comment: "HealthKit data type")

        case HKQuantityTypeIdentifier.basalBodyTemperature.rawValue:
            return NSLocalizedString("Basal Body Temperature", comment: "HealthKit data type")

        case HKQuantityTypeIdentifier.bloodAlcoholContent.rawValue:
            return NSLocalizedString("Blood Alcohol", comment: "HealthKit data type")

        case HKQuantityTypeIdentifier.bodyFatPercentage.rawValue:
            return NSLocalizedString("", comment: "HealthKit data type")

        case HKQuantityTypeIdentifier.bodyTemperature.rawValue:
            return NSLocalizedString("Body Temperature", comment: "HealthKit data type")

        case HKQuantityTypeIdentifier.dietaryBiotin.rawValue:
            return NSLocalizedString("Biotin", comment: "HealthKit data type")

        case HKQuantityTypeIdentifier.dietaryCalcium.rawValue:
            return NSLocalizedString("Calcium", comment: "HealthKit data type")

        case HKQuantityTypeIdentifier.dietaryChloride.rawValue:
            return NSLocalizedString("Chloride", comment: "HealthKit data type")

        case HKQuantityTypeIdentifier.dietaryChromium.rawValue:
            return NSLocalizedString("Chromium", comment: "HealthKit data type")

        case HKQuantityTypeIdentifier.dietaryCopper.rawValue:
            return NSLocalizedString("Copper", comment: "HealthKit data type")

        case HKQuantityTypeIdentifier.dietaryFiber.rawValue:
            return NSLocalizedString("Fiber", comment: "HealthKit data type")

        case HKQuantityTypeIdentifier.dietaryFolate.rawValue:
            return NSLocalizedString("Folate", comment: "HealthKit data type")

        case HKQuantityTypeIdentifier.dietaryIodine.rawValue:
            return NSLocalizedString("Iodine", comment: "HealthKit data type")

        case HKQuantityTypeIdentifier.dietaryIron.rawValue:
            return NSLocalizedString("Iron", comment: "HealthKit data type")

        case HKQuantityTypeIdentifier.dietaryMagnesium.rawValue:
            return NSLocalizedString("Magnesium", comment: "HealthKit data type")

        case HKQuantityTypeIdentifier.dietaryManganese.rawValue:
            return NSLocalizedString("Manganese", comment: "HealthKit data type")

        case HKQuantityTypeIdentifier.dietaryMolybdenum.rawValue:
            return NSLocalizedString("Molybdenum", comment: "HealthKit data type")

        case HKQuantityTypeIdentifier.dietaryNiacin.rawValue:
            return NSLocalizedString("Niacin", comment: "HealthKit data type")

        case HKQuantityTypeIdentifier.dietaryPantothenicAcid.rawValue:
            return NSLocalizedString("Pantothenic Acid", comment: "HealthKit data type")

        case HKQuantityTypeIdentifier.dietaryPhosphorus.rawValue:
            return NSLocalizedString("Phosphorus", comment: "HealthKit data type")

        case HKQuantityTypeIdentifier.dietaryPotassium.rawValue:
            return NSLocalizedString("Potassium", comment: "HealthKit data type")

        case HKQuantityTypeIdentifier.dietaryRiboflavin.rawValue:
            return NSLocalizedString("Riboflavin", comment: "HealthKit data type")

        case HKQuantityTypeIdentifier.dietarySelenium.rawValue:
            return NSLocalizedString("Selenium", comment: "HealthKit data type")

        case HKQuantityTypeIdentifier.dietaryThiamin.rawValue:
            return NSLocalizedString("Thiamin", comment: "HealthKit data type")

        case HKQuantityTypeIdentifier.dietaryVitaminA.rawValue:
            return NSLocalizedString("Vitamin A", comment: "HealthKit data type")

        case HKQuantityTypeIdentifier.dietaryVitaminB12.rawValue:
            return NSLocalizedString("Vitamin B12", comment: "HealthKit data type")

        case HKQuantityTypeIdentifier.dietaryVitaminB6.rawValue:
            return NSLocalizedString("Vitamin B6", comment: "HealthKit data type")

        case HKQuantityTypeIdentifier.dietaryVitaminC.rawValue:
            return NSLocalizedString("Vitamin C", comment: "HealthKit data type")

        case HKQuantityTypeIdentifier.dietaryVitaminD.rawValue:
            return NSLocalizedString("Vitamin D", comment: "HealthKit data type")

        case HKQuantityTypeIdentifier.dietaryVitaminE.rawValue:
            return NSLocalizedString("Vitamin E", comment: "HealthKit data type")

        case HKQuantityTypeIdentifier.dietaryVitaminK.rawValue:
            return NSLocalizedString("Vitamin K", comment: "HealthKit data type")

        case HKQuantityTypeIdentifier.dietaryZinc.rawValue:
            return NSLocalizedString("Zinc", comment: "HealthKit data type")

        case HKQuantityTypeIdentifier.electrodermalActivity.rawValue:
            return NSLocalizedString("Electrodermal Activity", comment: "HealthKit data type")

        case HKQuantityTypeIdentifier.forcedExpiratoryVolume1.rawValue:
            return NSLocalizedString("FEV1", comment: "HealthKit data type")

        case HKQuantityTypeIdentifier.forcedVitalCapacity.rawValue:
            return NSLocalizedString("FVC", comment: "HealthKit data type")

        case HKQuantityTypeIdentifier.height.rawValue:
            return NSLocalizedString("Height", comment: "HealthKit data type")

        case HKQuantityTypeIdentifier.inhalerUsage.rawValue:
            return NSLocalizedString("Inhaler Usage", comment: "HealthKit data type")

        case HKQuantityTypeIdentifier.leanBodyMass.rawValue:
            return NSLocalizedString("Lean Body Mass", comment: "HealthKit data type")

        case HKQuantityTypeIdentifier.nikeFuel.rawValue:
            return NSLocalizedString("Nike Fuel", comment: "HealthKit data type")

        case HKQuantityTypeIdentifier.numberOfTimesFallen.rawValue:
            return NSLocalizedString("Times Fallen", comment: "HealthKit data type")

        case HKQuantityTypeIdentifier.oxygenSaturation.rawValue:
            return NSLocalizedString("Blood Oxygen Saturation", comment: "HealthKit data type")

        case HKQuantityTypeIdentifier.peakExpiratoryFlowRate.rawValue:
            return NSLocalizedString("PEF", comment: "HealthKit data type")

        case HKQuantityTypeIdentifier.peripheralPerfusionIndex.rawValue:
            return NSLocalizedString("PPI", comment: "HealthKit data type")

        case HKQuantityTypeIdentifier.respiratoryRate.rawValue:
            return NSLocalizedString("RR", comment: "HealthKit data type")

        default:
            return nil
        }
    }
}
