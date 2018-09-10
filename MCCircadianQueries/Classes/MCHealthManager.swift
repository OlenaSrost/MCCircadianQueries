//fix for induvidual data
//
//  MCHealthManager.swift
//  MCCircadianQueries
//
//  Created by Yanif Ahmad on 1/14/17.
//  Copyright © 2017 Yanif Ahmad, Tom Woolf. All rights reserved.
//

import Foundation
import HealthKit
import Async
import SwiftDate
import SwiftyUserDefaults


// Typealiases
public typealias HMAuthorizationBlock  = (_ success: Bool, _ error: Error?) -> Void
public typealias HMSampleBlock         = (_ samples: [MCSample], _ error: Error?) -> Void
public typealias HMTypedSampleBlock    = (_ samples: [HKSampleType: [MCSample]], _ error: Error?) -> Void
public typealias HMAggregateBlock      = (_ aggregates: AggregateQueryResult, _ error: Error?) -> Void
public typealias HMCorrelationBlock    = ([MCSample], [MCSample], Error?) -> Void

public typealias HMCircadianBlock          = (_ intervals: [(Date, CircadianEvent)], _ error: Error?) -> Void
public typealias HMCircadianAggregateBlock = (_ aggregates: [(Date, Double)], _ error: Error?) -> Void
public typealias HMCircadianCategoryBlock  = (_ categories: [Int:Double], _ error: Error?) -> Void
public typealias HMFastingCorrelationBlock = ([(Date, Double, MCSample)], Error?) -> Void

public typealias HMAnchorQueryBlock    = (HKAnchoredObjectQuery, [HKSample]?, [HKDeletedObject]?, HKQueryAnchor?, Error?) -> Void
public typealias HMAnchorSamplesBlock  = (_ added: [HKSample], _ deleted: [HKDeletedObject], _ newAnchor: HKQueryAnchor?, _ error: Error?) -> Void
public typealias HMAnchorSamplesCBlock = (_ added: [HKSample], _ deleted: [HKDeletedObject], _ newAnchor: HKQueryAnchor?, _ error: Error?, _ completion: () -> Void) -> Void

public typealias HMSampleCache = Cache<MCSampleArray>
public typealias HMAggregateCache = Cache<MCAggregateArray>
public typealias HMCircadianCache = Cache<MCCircadianEventArray>

// Constants and enums.
public let HMDidUpdateRecentSamplesNotification = "HMDidUpdateRecentSamplesNotification"
public let HMDidUpdateAnyMeasures               = "HMDidUpdateAnyMeasures"
public let HMDidUpdateMeasuresPfx               = "HMDidUpdateMeasuresPfx"
public let HMDidUpdateCircadianEvents           = "HMDidUpdateCircadianEvents"
public let HMCircadianEventsDateUpdateKey       = "HMCircadianEventsDateUpdateKey"
public let HMDidUpdatedChartsData               = "HMDidUpdatedChartsData"

public let refDate  = Date(timeIntervalSinceReferenceDate: 0)
public let noAnchor = HKQueryAnchor(fromValue: Int(HKAnchoredObjectQueryNoAnchor))
public let noLimit  = Int(HKObjectQueryNoLimit)
public let dateAsc  = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
public let dateDesc = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
public let lastChartsDataCacheKey = "lastChartsDataCacheKey"

public let HMErrorDomain                        = "HMErrorDomain"
public let HMSampleTypeIdentifierSleepDuration  = "HMSampleTypeIdentifierSleepDuration"

public let stWorkout = 0.0
public let stSleep = 0.33
public let stFast = 0.66
public let stEat = 1.0

// Enums
public enum HealthManagerStatisticsRangeType : Int {
    case week = 0
    case month
    case year
}

public enum AggregateQueryResult {
    //    @available(iOS 9.0, *)
    case aggregatedSamples([MCAggregateSample])
    case statistics([HKStatistics])
    case none
}

public enum MetabolicCompassError: Error {
    case noInternet
    case healthKitSlow
    case healthKitNotAvailable
    case userError
    case dataMissing
    case invalidStatistics
    case localizedDescriptionError
    case notImplemented
}

/**
 This is the main manager of information reads/writes from HealthKit.  We use AnchorQueries to support continued updates.  Please see Apple Docs for syntax on reading/writing

 */
//@available(iOS 9.0, *)
open class MCHealthManager: NSObject {

    open static let sharedManager = MCHealthManager()

    open lazy var healthKitStore: HKHealthStore = HKHealthStore()

    // Query Caches
    open var sampleCache: HMSampleCache
    open var aggregateCache: HMAggregateCache
    open var circadianCache: HMCircadianCache

    // Cache invalidation types for specific measures.
    open var measureInvalidationsByType: Set<String> = [HKQuantityTypeIdentifier.heartRate.rawValue, HKQuantityTypeIdentifier.stepCount.rawValue]

    // Invalidation batching.
    fileprivate var anyMeasureNotifyTask: Async! = nil
    fileprivate var measureNotifyTaskByType: [String: Async?] = [:]
    fileprivate let notifyInterval = 2.0 // In seconds.

    public override init() {
        do {
            self.sampleCache = try HMSampleCache(name: "HMSampleCache")
            self.aggregateCache = try HMAggregateCache(name: "HMAggregateCache")
            self.circadianCache = try HMCircadianCache(name: "HMCircadianCache")
        } catch _ {
            fatalError("Unable to create HealthManager caches.")
        }
        super.init()
    }

    public func reset() {
        sampleCache.removeAllObjects()
        aggregateCache.removeAllObjects()
        circadianCache.removeAllObjects()
    }

    // Not guaranteed to be on main thread
    public func authorizeHealthKit(_ completion: @escaping HMAuthorizationBlock)
    {
        guard HKHealthStore.isHealthDataAvailable() else {
            let error = NSError(domain: HMErrorDomain, code: 2, userInfo: [NSLocalizedDescriptionKey: "HealthKit is not available in this Device"])
            completion(false, error)
            return
        }
        healthKitStore.requestAuthorization(toShare: HMConstants.sharedInstance.healthKitTypesToWrite, read: HMConstants.sharedInstance.healthKitTypesToRead, completion: completion)
    }

    // MARK: - Helpers
    public func durationOfCalendarUnitInSeconds(_ aggUnit: Calendar.Component) -> Double {
        switch aggUnit {
        case Calendar.Component.second:
            return 1.0
        case Calendar.Component.minute:
            return 60.0
        case Calendar.Component.hour:
            return 60.0*60.0
        case Calendar.Component.day:
            return 24.0*60.0*60.0
        case Calendar.Component.weekOfYear, Calendar.Component.weekOfMonth:
            return 7*24.0*60.0*60.0
        case Calendar.Component.month:
            return 31*24.0*60.0*60.0
        case Calendar.Component.year:
            return 365*24.0*60.0*60.0
        default:
            return Double.greatestFiniteMagnitude
        }
    }

    // MARK: - Predicate construction

    open func mealsSincePredicate(_ startDate: Date = Date().startOfDay, endDate: Date = Date().endOfDay) -> NSPredicate? {
        var predicate : NSPredicate? = nil
        let st=startDate
        let conjuncts = [
            HKQuery.predicateForSamples(withStart: st, end: endDate, options: HKQueryOptions()),
            HKQuery.predicateForWorkouts(with: HKWorkoutActivityType.preparationAndRecovery),
            HKQuery.predicateForObjects(withMetadataKey: "Meal Type")
        ]
        predicate = NSCompoundPredicate(andPredicateWithSubpredicates: conjuncts)
        return predicate
    }

    public func periodAggregation(_ statisticsRange: HealthManagerStatisticsRangeType) -> (NSPredicate, Date, Date, Calendar.Component) {
        var unit : Calendar.Component
        var startDate : Date
        var endDate : Date = Date()

        switch statisticsRange {
        case .week:
            unit = .day
            endDate = endDate.startOf(component: .day) + 1.days
            startDate = endDate - 1.weeks

        case .month:
            unit = .day
            endDate = endDate.startOf(component: .day) + 1.days
            startDate = endDate - 1.months

        case .year:
            unit = .month
            endDate = endDate.startOf(component: .month) + 1.months
            startDate = endDate - 1.years
        }

        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: endDate, options: HKQueryOptions())
        return (predicate, startDate, endDate, unit)
    }

    // MARK: - Sample testing

    public func isGeneratedSample(_ sample: HKSample) -> Bool {
        if let unwrappedMetadata = sample.metadata, let _ = unwrappedMetadata[HMConstants.sharedInstance.generatedSampleKey] {
            return true
        }
        return false
    }

    // MARK: - Characteristic type queries

    public func getBiologicalSex() -> HKBiologicalSexObject? {
        do {
            return try self.healthKitStore.biologicalSex()
        } catch {
            print("Failed to get biological sex.")
        }
        return nil
    }

    // MARK: - HealthKit sample and statistics retrieval.

    // Retrieves Healthit samples for the given type, predicate, limit and sorting
    // Completion handler is on background queue
    open func fetchSamplesOfType(_ sampleType: HKSampleType,
                                 predicate: NSPredicate? = nil,
                                 limit: Int = 0,
                                 sortDescriptors: [NSSortDescriptor] = [dateAsc],
                                 completion: @escaping HMSampleBlock) {

        let query = HKSampleQuery(sampleType: sampleType,
                                  predicate: predicate,
                                  limit: limit,
                                  sortDescriptors: sortDescriptors) {
                                    (query, samples, error) -> Void in
                                    guard error == nil else {
                                        completion([], error)
                                        return
                                    }
                                    completion(samples?.map { $0 as MCSample } ?? [], nil)
        }
        healthKitStore.execute(query)
    }

    // Retrieves the HealthKit samples for the given UUIDs, further filtering them according to the specified predicate.
    public func fetchSamplesByUUID(_ sampleType: HKSampleType,
                                   uuids: Set<UUID>,
                                   predicate: NSPredicate? = nil,
                                   limit: Int = noLimit,
                                   sortDescriptors: [NSSortDescriptor] = [dateAsc],
                                   completion: @escaping HMSampleBlock) {
        var uuidPredicate: NSPredicate = HKQuery.predicateForObjects(with: uuids)
        if let p = predicate {
            uuidPredicate = NSCompoundPredicate(andPredicateWithSubpredicates: [p, uuidPredicate])
        }
        fetchSamplesOfType(sampleType, predicate: uuidPredicate, limit: limit, sortDescriptors: sortDescriptors, completion: completion)
    }


    // Fetches the latest HealthKit sample of the given type.
    public func fetchMostRecentSample(_ sampleType: HKSampleType, completion: @escaping HMSampleBlock) {
        fetchSamplesOfType(sampleType, predicate: nil, limit: 1, sortDescriptors: [dateDesc], completion: completion)
    }

    // Fetches HealthKit samples for multiple types, using GCD to retrieve each type asynchronously and concurrently.
    public func fetchMostRecentSamples(ofTypes types: [HKSampleType], completion: @escaping HMTypedSampleBlock) {
        let group = DispatchGroup()
        var samples = [HKSampleType: [MCSample]]()

        let updateSamples :  (@escaping (MCSampleArray, CacheExpiry) -> Void, @escaping (NSError?) -> Void, HKSampleType, [MCSample], Error?) -> Void = {
            (success, failure, type, statistics, error) in
            guard error == nil else {
                let err = NSError(domain: "", code: 0, userInfo: [NSLocalizedDescriptionKey : error?.localizedDescription])
                failure(err)
                return
            }

            guard statistics.isEmpty == false else {
                let err = NSError(domain: "", code: 0, userInfo: [NSLocalizedDescriptionKey : error?.localizedDescription])
                failure(err)
                return
            }

            samples[type] = statistics
            success(MCSampleArray(samples: statistics), .never)
        }

        let onCatOrCorr = { (success, failure, type) in
            self.fetchMostRecentSample(type) { (statistics, error) in
                updateSamples(success, failure, type, statistics, error)
            }
        }


        let onWorkout : (@escaping (MCSampleArray, CacheExpiry) -> Void, @escaping (NSError?) -> Void, HKSampleType) -> Void = { (success, failure, type) in
            self.fetchPreparationAndRecoveryWorkout(false) { (statistics, error) in
                // let err = Error(domain: "", code: 0, userInfo: [NSLocalizedDescriptionKey : error.localizedDescription])
                updateSamples(success, failure, type, statistics, error)
            }
        }

        let onStatistic : (@escaping (MCSampleArray, CacheExpiry) -> Void, @escaping (NSError?) -> Void, HKSampleType) -> Void = { (success, failure, type) in
            // First run a pilot query to retrieve the acquisition date of the last sample.
            self.fetchMostRecentSample(type) { (samples, error) in
                guard error == nil else {
                    //        log.error("Could not fetch recent samples for \(type.displayText): \(error!.localizedDescription)")
                    let err = NSError(domain: "", code: 0, userInfo: [NSLocalizedDescriptionKey : error?.localizedDescription ?? "Could not fetch recent samples for \(String(describing: type.displayText)): \(error!.localizedDescription)"])
                    failure(err)
                    return
                }

                if let lastSample = samples.last {
                    // Then run a statistics query to aggregate relative to the recent sample date.
                    let recentWindowStartDate = lastSample.startDate - 4.days
                    let predicate = HKSampleQuery.predicateForSamples(withStart: recentWindowStartDate, end: nil, options: [])
                    self.fetchStatisticsOfType(type, predicate: predicate) { (statistics, error) in
                        updateSamples(success, failure, type, statistics, error)
                    }
                } else {
                    updateSamples(success, failure, type, samples, error)
                }
            }
        }

        if types.count > 5 {
            let debugType = types[5]
            var array = [HKSampleType]()
            array.append(debugType)
        }
        
        types.forEach { (type) -> () in
            group.enter()
            let key = type.identifier
            self.sampleCache.setObject(forKey:key,
                                       cacheBlock: { (success, failure) in
                                        if (type.identifier == HKCategoryTypeIdentifier.sleepAnalysis.rawValue) {
                                            onCatOrCorr(success, failure, type)
                                        } else if (type.identifier == HKCorrelationTypeIdentifier.bloodPressure.rawValue) {
                                            onCatOrCorr(success, failure, type)
                                        } else if (type.identifier == HKWorkoutTypeIdentifier) {
                                            return
                                                onWorkout(success, failure, type)
                                        } else {
                                            onStatistic(success, failure, type)
                                        }
            },
                                       completion: { (samplesCoding, cacheHit, error) in
                                        guard error == nil else {
                                            group.leave()
                                            return
                                        }
                                        if let coding = samplesCoding, cacheHit {
                                            samples[type] = coding.samples
                                        }
                                        group.leave()
            })
        }

        group.notify(queue: DispatchQueue.main) {
            completion(samples, nil)
        }
    }

    // MARK: - Bulk generic retrieval

    // Fetches HealthKit samples for multiple types, using GCD to retrieve each type asynchronously and concurrently.
    public func fetchSamples(_ typesAndPredicates: [HKSampleType: NSPredicate], completion: @escaping HMTypedSampleBlock) {
        let group = DispatchGroup()
        var samplesByType = [HKSampleType: [MCSample]]()
        var errors: [Error] = []
        typesAndPredicates.forEach { (type, predicate) -> () in
            group.enter()
            fetchSamplesOfType(type, predicate: predicate, limit: noLimit) { (samples, error) in
                guard error == nil else {
                    errors.append(error!)
                    group.leave()
                    return
                }
                guard samples.isEmpty == false else {
                    //                   log.debug("No recent samples available for \(type.displayText)", feature: "status:fetchSamples")
                    group.leave()
                    return
                }
                samplesByType[type] = samples
                group.leave()
            }
        }

        group.notify(queue: DispatchQueue.global(qos:.userInitiated)) {
            _ = errors.count > 0 ? "Failure" : "Success"

            if errors.count > 0 {
                completion([:], errors.first)
            } else {
                completion(samplesByType, nil)
            }
        }
    }


    // MARK: - Aggregate caching helpers.
    public func getCacheDateKeyFormatter(_ aggUnit: Calendar.Component) -> DateFormatter {
        let formatter = DateFormatter()

        // Return the formatter based on the finest-grained unit.
        if aggUnit.hashValue < (24*60*60) {
            formatter.dateFormat = "yyMMdd"
        } else if aggUnit.hashValue < (7*24*60*60) {
            formatter.dateFormat = "yyww"
        } else if aggUnit.hashValue < (31*24*60*60) {
            formatter.dateFormat = "yyMM"
        } else if aggUnit.hashValue < (365*24*60*60) {
            formatter.dateFormat = "yy"
        } else {
            fatalError("Unsupported aggregation calendar unit: \(aggUnit)")
        }

        return formatter
    }

    // Cache keys.
    public func getAggregateCacheKey(_ keyPrefix: String, aggUnit: Calendar.Component, aggOp: HKStatisticsOptions) -> String {
        let currentUnit = Date().startOf(component: aggUnit)
        let formatter = getCacheDateKeyFormatter(aggUnit)
        return "\(keyPrefix)_\(aggOp.rawValue)_\(formatter.string(from: currentUnit))"
    }

    public func getPeriodCacheKey(_ keyPrefix: String, aggOp: HKStatisticsOptions, period: HealthManagerStatisticsRangeType) -> String {
        return "\(keyPrefix)_\(aggOp.rawValue)_\(period.rawValue)"
    }

    public func getCacheExpiry(_ period: HealthManagerStatisticsRangeType) -> Date {
        switch period {
        case .week:
            return Date() + 2.minutes

        case .month:
            return Date() + 5.minutes

        case .year:
            return Date() + 1.days
        }
    }


    // MARK: - Aggregate retrieval.

    public func queryResultAsAggregates(_ aggOp: HKStatisticsOptions,
                                        result: AggregateQueryResult,
                                        error: Error?,
                                        completion: @escaping ([MCAggregateSample], Error?) -> Void) {
        // MCAggregateSample.final is idempotent, thus this function can be called multiple times.
        let finalize: (MCAggregateSample) -> MCAggregateSample = { var agg = $0; agg.final(); return agg }

        guard error == nil else {
            completion([], error)
            return
        }

        switch result {
        case .aggregatedSamples(let aggregates):
            completion(aggregates.map(finalize), error)
        case .statistics(let statistics):
            completion(statistics.map { return MCAggregateSample(statistic: $0, op: aggOp) }, error)
        case .none:
            completion([], error)
        }
    }

    // Convert an AggregateQueryResult value into an MCSample array, and fire the completion.
    public func queryResultAsSamples(_ result: AggregateQueryResult, error: Error?, completion:  HMSampleBlock) {
        // MCAggregateSample.final is idempotent, thus this function can be called multiple times.
        let finalize: (MCAggregateSample) -> MCSample = { var agg = $0; agg.final(); return agg as MCSample }

        guard error == nil else {
            completion([], error)
            return
        }
        switch result {
        case .aggregatedSamples(let aggregates):
            completion(aggregates.map(finalize), error)
        case .statistics(let statistics):
            completion(statistics.map { $0 as MCSample }, error)
        case .none:
            completion([], error)
        }
    }

    public func aggregateSamplesManually(_ sampleType: HKSampleType, aggOp: HKStatisticsOptions, samples: [MCSample]) -> MCAggregateSample {
        if samples.count == 0 {
            return MCAggregateSample(value: 0.0, sampleType: sampleType, op: aggOp)
        }

        var agg = MCAggregateSample(sample: samples[0], op: aggOp)
        samples.dropFirst().forEach { sample in agg.incr(sample) }
        return agg
    }

    // Group-by the desired aggregation calendar unit, returning a dictionary of MCAggregateSamples.
    public func aggregateByPeriod(_ aggUnit: Calendar.Component, aggOp: HKStatisticsOptions, samples: [MCSample]) -> [Date: MCAggregateSample] {
        var byPeriod: [Date: MCAggregateSample] = [:]
        samples.forEach { sample in
            let periodStart = sample.startDate.startOf(component: aggUnit)
            if var agg = byPeriod[periodStart] {
                agg.incr(sample)
                byPeriod[periodStart] = agg
            } else {
                byPeriod[periodStart] = MCAggregateSample(sample: sample, op: aggOp)
            }
        }
        return byPeriod
    }

    public func finalizePartialAggregation(_ aggUnit: Calendar.Component,
                                           aggOp: HKStatisticsOptions,
                                           result: AggregateQueryResult,
                                           error: Error?,
                                           completion: @escaping (([MCAggregateSample], Error?) -> Void)) {
        queryResultAsSamples(result, error: error) { (samples, error) in
            guard error == nil else {
                completion([], error!)
                return
            }
            let byPeriod = aggregateByPeriod(aggUnit, aggOp: aggOp, samples: samples)
            completion(byPeriod.sorted(by: { (a,b) in return a.0 < b.0 }).map { $0.1 }, nil)
        }
    }

    public func finalizePartialAggregationAsSamples(_ aggUnit: Calendar.Component,
                                                    aggOp: HKStatisticsOptions,
                                                    result: AggregateQueryResult,
                                                    error: Error?,
                                                    completion: @escaping HMSampleBlock) {
        queryResultAsSamples(result, error: error) { (samples, error) in
            guard error == nil else {
                completion([], error)
                return
            }
            let byPeriod = self.aggregateByPeriod(aggUnit, aggOp: aggOp, samples: samples)
            completion(byPeriod.sorted(by: { (a,b) in return a.0 < b.0 }).map { $0.1 }, nil)
        }
    }

    public func coverAggregatePeriod<T>(_ tag: String, sampleType: HKSampleType, startDate: Date, endDate: Date,
                                     aggUnit: Calendar.Component, aggOp: HKStatisticsOptions,
                                     sparseAggs: [MCAggregateSample], withFinalization: Bool = false,
                                     transform: (MCAggregateSample) -> T)
        -> [T] {
            // MCAggregateSample.final is idempotent, thus this function can be called multiple times.
            let finalize: (MCAggregateSample) -> MCAggregateSample = { var agg = $0; agg.final(); return agg }

            var delta = DateComponents()
            delta.setValue(1, for: aggUnit)

            var i: Int = 0
            var aggregates: [T] = []
            let dateRange = DateRange(startDate: startDate, endDate: endDate, stepUnits: aggUnit)

            while i < sparseAggs.count && sparseAggs[i].startDate.startOf(component: aggUnit) < startDate.startOf(component: aggUnit) {
                i += 1
            }

            for date in dateRange {
                if i < sparseAggs.count && date.startOf(component: aggUnit) == sparseAggs[i].startDate.startOf(component: aggUnit) {
                    aggregates.append(transform(withFinalization ? finalize(sparseAggs[i]) : sparseAggs[i]))
                    i += 1
                } else {
                    aggregates.append(transform(MCAggregateSample(startDate: date, endDate: date + delta, value: 0.0, sampleType: sampleType, op: aggOp)))
                }
            }
            return aggregates
    }

    public func coverStatisticsPeriod<T>(_ tag: String, sampleType: HKSampleType, startDate: Date, endDate: Date,
                                      aggUnit: Calendar.Component, aggOp: HKStatisticsOptions,
                                      sparseStats: [HKStatistics], transform: (MCAggregateSample) -> T)
        -> [T] {
            var delta = DateComponents()
            delta.setValue(1, for: aggUnit)

            var i: Int = 0
            var statistics: [T] = []
            let dateRange = DateRange(startDate: startDate, endDate: endDate, stepUnits: aggUnit)

            while i < sparseStats.count && sparseStats[i].startDate.startOf(component: aggUnit) < startDate.startOf(component: aggUnit) {
                i += 1
            }

            for date in dateRange {
                if i < sparseStats.count && date.startOf(component: aggUnit) == sparseStats[i].startDate.startOf(component: aggUnit) {
                    statistics.append(transform(MCAggregateSample(statistic: sparseStats[i], op: aggOp)))
                    i += 1
                } else {
                    statistics.append(transform(MCAggregateSample(startDate: date, endDate: date + delta, value: 0.0, sampleType: sampleType, op: aggOp)))

                }
            }
            return statistics
    }

    // Period-covering variants of the above helpers.
    // These ensure that there is a sample for every calendar unit contained within the given time period.
    public func queryResultAsAggregatesForPeriod(_ sampleType: HKSampleType,
                                                 startDate: Date,
                                                 endDate: Date,
                                                 aggUnit: Calendar.Component,
                                                 aggOp: HKStatisticsOptions,
                                                 result: AggregateQueryResult,
                                                 error: Error?,
                                                 completion: @escaping ([MCAggregateSample], Error?) -> Void) {
        guard error == nil else {
            completion([], error)
            return
        }

        var aggregates: [MCAggregateSample] = []

        switch result {
        case .aggregatedSamples(let sparseAggs):
            aggregates = coverAggregatePeriod("QRAP", sampleType: sampleType, startDate: startDate, endDate: endDate,
                                              aggUnit: aggUnit, aggOp: aggOp, sparseAggs: sparseAggs, withFinalization: true, transform: { $0 })

        case .statistics(let statistics):
            aggregates = coverStatisticsPeriod("QRAP", sampleType: sampleType, startDate: startDate, endDate: endDate,
                                               aggUnit: aggUnit, aggOp: aggOp, sparseStats: statistics, transform: { $0 })

        case .none:
            aggregates = []
        }

        completion(aggregates, error)
    }

    public func queryResultAsSamplesForPeriod(_ sampleType: HKSampleType,
                                              startDate: Date,
                                              endDate: Date,
                                              aggUnit: Calendar.Component,
                                              aggOp: HKStatisticsOptions,
                                              result: AggregateQueryResult,
                                              error: Error?,
                                              completion: HMSampleBlock) {
        guard error == nil else {
            completion([], error)
            return
        }

        var samples: [MCSample] = []

        switch result {
        case .aggregatedSamples(let sparseAggs):
            samples = coverAggregatePeriod("QRASP", sampleType: sampleType,
                                           startDate: startDate,
                                           endDate: endDate,
                                           aggUnit: aggUnit,
                                           aggOp: aggOp,
                                           sparseAggs: sparseAggs,
                                           withFinalization: true,
                                           transform: { $0 as MCSample })

        case .statistics(let statistics):
            samples = coverStatisticsPeriod("QRASP", sampleType: sampleType,
                                            startDate: startDate,
                                            endDate: endDate,
                                            aggUnit: aggUnit,
                                            aggOp: aggOp,
                                            sparseStats: statistics,
                                            transform: { $0 as MCSample })

        case .none:
            samples = []
        }

        completion(samples, error)
    }


    public func finalizePartialAggregationForPeriod(_ sampleType: HKSampleType,
                                                    startDate: Date,
                                                    endDate: Date,
                                                    aggUnit: Calendar.Component,
                                                    aggOp: HKStatisticsOptions,
                                                    result: AggregateQueryResult,
                                                    error: Error?,
                                                    completion: @escaping (([MCAggregateSample], Error?) -> Void)) {
        queryResultAsSamples(result, error: error) { (samples, error) in
            guard error == nil else {
                completion([], error! )
                return
            }
            let byPeriod = aggregateByPeriod(aggUnit, aggOp: aggOp, samples: samples)
            let sparseAggs = byPeriod.sorted(by: { (a,b) in return a.0 < b.0 }).map { $0.1 }
            let aggregates = coverAggregatePeriod("FPAP", sampleType: sampleType,
                                                  startDate: startDate,
                                                  endDate: endDate,
                                                  aggUnit: aggUnit,
                                                  aggOp: aggOp,
                                                  sparseAggs: sparseAggs,
                                                  transform: { $0 })
            completion(aggregates, nil)
        }
    }

    public func finalizePartialAggregationAsSamplesForPeriod(_ sampleType: HKSampleType,
                                                             startDate: Date,
                                                             endDate: Date,
                                                             aggUnit: Calendar.Component,
                                                             aggOp: HKStatisticsOptions,
                                                             result: AggregateQueryResult,
                                                             error: Error?,
                                                             completion: @escaping HMSampleBlock) {
        queryResultAsSamples(result, error: error) { (samples, error) in
            guard error == nil else {
                completion([], error)
                return
            }

            let byPeriod = aggregateByPeriod(aggUnit, aggOp: aggOp, samples: samples)
            let sparseAggs = byPeriod.sorted(by: { (a,b) in return a.0 < b.0 }).map { $0.1 }
            let samples = coverAggregatePeriod("FPASP", sampleType: sampleType, startDate: startDate, endDate: endDate,
                                               aggUnit: aggUnit, aggOp: aggOp, sparseAggs: sparseAggs, transform: { $0 as MCSample })

            completion(samples, error)
        }
    }


    // Returns aggregate values by processing samples retrieved from HealthKit.
    // We return an aggregate for each calendar unit as specified by the aggUnit parameter.
    // Here the aggregation is done at the application-level (rather than inside HealthKit, as a statistics query).
    public func fetchSampleAggregatesOfType(
        _ sampleType: HKSampleType,
        predicate: NSPredicate? = nil,
        aggUnit: Calendar.Component = .day,
        aggOp: HKStatisticsOptions,
        limit: Int = noLimit,
        sortDescriptors: [NSSortDescriptor] = [dateAsc],
        completion: @escaping HMAggregateBlock) {
        fetchSamplesOfType(sampleType, predicate: predicate, limit: limit, sortDescriptors: sortDescriptors) { samples, error in
            guard error == nil else {
                completion(.aggregatedSamples([]), error)
                return
            }
            let byPeriod = self.aggregateByPeriod(aggUnit, aggOp: aggOp, samples: samples)
            completion(.aggregatedSamples(byPeriod.sorted(by: { (a,b) in return a.0 < b.0 }).map { $0.1 }), nil)
        }
    }

    // Returns aggregate values as above, except converting to MCSamples for the completion.
    public func fetchSampleStatisticsOfType(
        _ sampleType: HKSampleType, predicate: NSPredicate? = nil,
        aggUnit: Calendar.Component = .day, aggOp: HKStatisticsOptions,
        limit: Int = noLimit, sortDescriptors: [NSSortDescriptor] = [dateAsc], completion: @escaping HMSampleBlock)
    {

        fetchSampleAggregatesOfType(sampleType, predicate: predicate, aggUnit: aggUnit, aggOp: aggOp, limit: limit, sortDescriptors: sortDescriptors) {
            self.queryResultAsSamples($0, error: $1, completion: completion)
        }
    }

    // Fetches statistics as defined by the predicate, aggregation unit, and per-type operation.
    // The predicate should span the time interval of interest for the query.
    // The aggregation unit defines the granularity at which statistics are computed (i.e., per day/week/month/year).
    // The aggregation operator defines the type of aggregate (avg/min/max/sum) for each valid HKSampleType.
    //
    public func fetchAggregatesOfType(_ sampleType: HKSampleType,
                                      predicate: NSPredicate? = nil,
                                      aggUnit: Calendar.Component = .day,
                                      aggOp: HKStatisticsOptions,
                                      completion: @escaping HMAggregateBlock) {
        switch sampleType {
        case is HKCategoryType:
            fallthrough

        case is HKCorrelationType:
            fallthrough

        case is HKWorkoutType:
            fetchSampleAggregatesOfType(sampleType, predicate: predicate, aggUnit: aggUnit, aggOp: aggOp, completion: completion)

        case is HKQuantityType:
            var interval = DateComponents()
            interval.setValue(1, for: aggUnit)

            // Indicates whether to use a HKStatisticsQuery or a HKSampleQuery.
            var querySamples = false

            let quantityType = sampleType as! HKQuantityType

            switch quantityType.aggregationStyle {
            case .discrete:
                querySamples = aggOp.contains(.cumulativeSum)
            case .cumulative:
                querySamples = aggOp.contains(.discreteAverage) || aggOp.contains(.discreteMin) || aggOp.contains(.discreteMax)
            }

            if querySamples {
                // Query processing via manual aggregation over HKSample numeralValues.
                // This allows us to calculate avg/min/max over cumulative types, and sums over discrete types.
                fetchSampleAggregatesOfType(sampleType, predicate: predicate, aggUnit: aggUnit, aggOp: aggOp, completion: completion)
            } else {
                // Query processing via a HealthKit statistics query.
                // Set the anchor date to the start of the temporal aggregation unit (i.e., day/week/month/year).
                let anchorDate = Date().startOf(component: aggUnit)

                // Create the query
                let query = HKStatisticsCollectionQuery(quantityType: quantityType,
                                                        quantitySamplePredicate: predicate,
                                                        options: aggOp,
                                                        anchorDate: anchorDate,
                                                        intervalComponents: interval)
                query.initialResultsHandler = { query, results, error in
                    guard error == nil else {
                        completion(.none, error)
                        return
                    }
                    completion(.statistics(results?.statistics() ?? []), nil)
                }
                healthKitStore.execute(query)
            }

        default:
            let err = NSError(domain: HMErrorDomain, code: 1048576, userInfo: [NSLocalizedDescriptionKey: "Not implemented"])
            completion(.none, err)
        }
    }

    // Statistics calculation, with a default aggregation operator.
    public func fetchStatisticsOfType(_ sampleType: HKSampleType,
                                      predicate: NSPredicate? = nil,
                                      aggUnit: Calendar.Component = .day,
                                      completion: @escaping HMSampleBlock) {
        fetchAggregatesOfType(sampleType, predicate: predicate, aggUnit: aggUnit, aggOp: sampleType.aggregationOptions) {
            self.queryResultAsSamples($0, error: $1, completion: completion)
        }
    }

    // Statistics calculation over a predefined period.
    public func fetchStatisticsOfTypeForPeriod(_ sampleType: HKSampleType,
                                               period: HealthManagerStatisticsRangeType,
                                               aggOp: HKStatisticsOptions,
                                               completion: @escaping HMSampleBlock) {
        let (predicate, _, _, aggUnit) = periodAggregation(period)
        fetchAggregatesOfType(sampleType, predicate: predicate, aggUnit: aggUnit, aggOp: aggOp) {
            self.queryResultAsSamples($0, error: $1, completion: completion)
        }
    }

    // Cache-based equivalent of fetchStatisticsOfTypeForPeriod
    public func getStatisticsOfTypeForPeriod(_ keyPrefix: String,
                                             sampleType: HKSampleType,
                                             period: HealthManagerStatisticsRangeType,
                                             aggOp: HKStatisticsOptions,
                                             completion: @escaping HMSampleBlock) {

        let (predicate, _, _, aggUnit) = periodAggregation(period)
        let key = getPeriodCacheKey(keyPrefix, aggOp: aggOp, period: period)

        aggregateCache.setObject(forKey:key, cacheBlock: { success, failure in
            self.fetchAggregatesOfType(sampleType, predicate: predicate, aggUnit: aggUnit, aggOp: aggOp) {
                self.queryResultAsAggregates(aggOp, result: $0, error: $1) { (aggregates, error) in
                    guard error == nil else {
                        failure(error! as NSError)
                        return
                    }
                    success(MCAggregateArray(aggregates: aggregates), .date(self.getCacheExpiry(period)))
                }
            }
        }, completion: {object, isLoadedFromCache, error in
            if let aggArray = object {
                self.queryResultAsSamples(.aggregatedSamples(aggArray.aggregates), error: error, completion: completion)
            } else {
                completion([], error)
            }
        })
    }

    // Statistics calculation over a predefined period.
    // This is similar to the method above, except that it computes a daily average for cumulative metrics
    // when requesting a yearly period.
    public func fetchDailyStatisticsOfTypeForPeriod(_ sampleType: HKSampleType,
                                                    period: HealthManagerStatisticsRangeType,
                                                    aggOp: HKStatisticsOptions,
                                                    completion: @escaping HMSampleBlock)
    {
        let (predicate, startDate, endDate, aggUnit) = periodAggregation(period)
        let byDay = sampleType.aggregationOptions == .cumulativeSum

        fetchAggregatesOfType(sampleType, predicate: predicate, aggUnit: byDay ? .day : aggUnit, aggOp: byDay ? .cumulativeSum : aggOp) {
            if byDay {
                // Compute aggregates at aggUnit granularity by first partially aggregating per day,
                // and then computing final aggregates as daily averages.
                self.finalizePartialAggregationAsSamplesForPeriod(sampleType, startDate: startDate, endDate: endDate,
                                                                  aggUnit: aggUnit, aggOp: aggOp, result: $0, error: $1, completion: completion)
            } else {
                self.queryResultAsSamplesForPeriod(sampleType, startDate: startDate, endDate: endDate,
                                                   aggUnit: aggUnit, aggOp: aggOp, result: $0, error: $1, completion: completion)
            }
        }
    }

    // Cache-based equivalent of fetchDailyStatisticsOfTypeForPeriod
    open func getDailyStatisticsOfTypeForPeriod(_ keyPrefix: String,
                                                sampleType: HKSampleType,
                                                period: HealthManagerStatisticsRangeType,
                                                aggOp: HKStatisticsOptions,
                                                completion: @escaping HMSampleBlock) {
        let (predicate, startDate, endDate, aggUnit) = periodAggregation(period)
        let key = getPeriodCacheKey(keyPrefix, aggOp: aggOp, period: period)

        let byDay = sampleType.aggregationOptions == .cumulativeSum

        aggregateCache.setObject(forKey:key, cacheBlock: { success, failure in
            print("aggregateCache.setObject")

            let doCache : ([MCAggregateSample], Error?) -> Void = { (aggregates, error) in
                guard error == nil else {
                    print ("guard error == nil else")
                    failure(error as NSError?)
                    return
                }
                print ("success(MCAggregateArray")
                success(MCAggregateArray(aggregates: aggregates), .date(self.getCacheExpiry(period)))
            }
            print ("self.fetchAggregatesOfType")
            self.fetchAggregatesOfType(sampleType, predicate: predicate, aggUnit: byDay ? .day : aggUnit, aggOp: byDay ? .cumulativeSum : aggOp) {
                if byDay {
                    self.finalizePartialAggregationForPeriod(sampleType, startDate: startDate, endDate: endDate, aggUnit: aggUnit, aggOp: aggOp, result: $0, error: $1, completion: doCache)
                } else {
                    self.queryResultAsAggregatesForPeriod(sampleType, startDate: startDate, endDate: endDate,
                                                          aggUnit: aggUnit, aggOp: aggOp, result: $0, error: $1, completion: doCache)
                }
            }
        }, completion: {object, isLoadedFromCache, error in
            if let aggArray = object {
                self.queryResultAsSamples(.aggregatedSamples(aggArray.aggregates), error: error, completion: completion)
            } else {
                completion([], error)
            }
        })
    }

    // Returns the extreme values over a predefined period.
    public func fetchMinMaxOfTypeForPeriod(_ sampleType: HKSampleType,
                                           period: HealthManagerStatisticsRangeType,
                                           completion: @escaping ([MCSample], [MCSample], Error?) -> Void)
    {
        let (predicate, startDate, endDate, aggUnit) = periodAggregation(period)

        let finalize : (HKStatisticsOptions, MCAggregateSample) -> MCSample = {
            var agg = $1; agg.finalAggregate($0); return agg as MCSample
        }

        fetchAggregatesOfType(sampleType, predicate: predicate, aggUnit: aggUnit, aggOp: [.discreteMin, .discreteMax]) {
            self.queryResultAsAggregatesForPeriod(sampleType, startDate: startDate, endDate: endDate,
                                                  aggUnit: aggUnit, aggOp: [.discreteMin, .discreteMax], result: $0, error: $1)
            { (aggregates, error) in
                guard error == nil else {
                    completion([], [], error)
                    return
                }
                completion(aggregates.map { finalize(.discreteMin, $0) }, aggregates.map { finalize(.discreteMax, $0) }, error)
            }
        }
    }

    // Cache-based equivalent of fetchMinMaxOfTypeForPeriod
    public func getMinMaxOfTypeForPeriod(_ keyPrefix: String,
                                         sampleType: HKSampleType,
                                         period: HealthManagerStatisticsRangeType,
                                         completion: @escaping ([MCSample], [MCSample], Error?) -> Void)
    {
        let aggOp: HKStatisticsOptions = [.discreteMin, .discreteMax]
        let (predicate, startDate, endDate, aggUnit) = periodAggregation(period)
        let key = getPeriodCacheKey(keyPrefix, aggOp: aggOp, period: period)

        let finalize : (HKStatisticsOptions, MCAggregateSample) -> MCSample = {
            var agg = $1; agg.finalAggregate($0); return agg as MCSample
        }

        aggregateCache.setObject(forKey:key, cacheBlock: { success, failure in
            self.fetchAggregatesOfType(sampleType, predicate: predicate, aggUnit: aggUnit, aggOp: aggOp) {
                self.queryResultAsAggregatesForPeriod(sampleType, startDate: startDate, endDate: endDate,
                                                      aggUnit: aggUnit, aggOp: aggOp, result: $0, error: $1)
                { (aggregates, error) in
                    guard error == nil else {
                        failure(error as NSError?)
                        return
                    }
                    success(MCAggregateArray(aggregates: aggregates), .date(self.getCacheExpiry(period)))
                }
            }
        }, completion: {object, isLoadedFromCache, error in
            if let aggArray = object {
                completion(aggArray.aggregates.map { finalize(.discreteMin, $0) }, aggArray.aggregates.map { finalize(.discreteMax, $0) }, error)
            } else {
                completion([], [], error)
            }
        })
    }

    // Completion handler is on main queue
    public func correlateStatisticsOfType(_ type: HKSampleType, withType type2: HKSampleType,
                                          pred1: NSPredicate, pred2: NSPredicate, completion: @escaping HMCorrelationBlock) {
        var results1: [MCSample]?
        var results2: [MCSample]?

        func intersect(_ arr1: [MCSample], arr2: [MCSample]) -> [(Date, MCSample, MCSample)] {
            var output: [(Date, MCSample, MCSample)] = []
            var arr1ByDay : [Date: MCSample] = [:]
            arr1.forEach { s in
                let start = s.startDate.startOf(component: .day)
                arr1ByDay.updateValue(s, forKey: start)
            }

            arr2.forEach { s in
                let start = s.startDate.startOf(component: .day)
                if let match = arr1ByDay[start] { output.append((start, match, s)) }
            }
            return output
        }

        let group = DispatchGroup()
        group.enter()
        fetchStatisticsOfType(type, predicate: pred1) { (results, error) -> Void in
            guard error == nil else {
                completion([], [], error)
                group.leave()
                return
            }
            results1 = results
            group.leave()
        }
        group.enter()
        fetchStatisticsOfType(type2, predicate: pred2) { (results, error) -> Void in
            guard error == nil else {
                completion([], [], error)
                group.leave()
                return
            }
            results2 = results
            group.leave()
        }

        group.notify(queue: DispatchQueue.global(qos:.background)) {
            guard !(results1 == nil || results2 == nil) else {
                let desc = results1 == nil ? (results2 == nil ? "LHS and RHS" : "LHS") : "RHS"
                let err = NSError(domain: HMErrorDomain, code: 1048576, userInfo: [NSLocalizedDescriptionKey: "Invalid \(desc) statistics"])
                completion([], [], err)
                return
            }
            var zipped = intersect(results1!, arr2: results2!)
            zipped.sort { (a,b) in a.1.numeralValue! < b.1.numeralValue! }
            completion(zipped.map { $0.1 }, zipped.map { $0.2 }, nil)
        }
    }


    // MARK: - Circadian event retrieval.

    // Query food diary events stored as prep and recovery workouts in HealthKit
    public func fetchPreparationAndRecoveryWorkout(_ oldestFirst: Bool, beginDate: Date = Date(), completion:  @escaping HMSampleBlock)
    {
        let predicate = mealsSincePredicate(beginDate)
        let sortDescriptor = NSSortDescriptor(key:HKSampleSortIdentifierStartDate, ascending: oldestFirst)
        self.fetchSamplesOfType(HKWorkoutType.workoutType(), predicate: predicate, limit: noLimit, sortDescriptors: [sortDescriptor], completion: completion)
    }

    fileprivate func decomposeCircadianDateRangeForCaching(_ startDate: Date, endDate: Date) -> (Bool, [Date]) {
        let recent = Date() - 1.months
        // For now, we only use caching/decomposition for recent queries, that access less than 2 weeks of data.
        if recent < startDate && recent < endDate && endDate < startDate + 2.weeks {
            let dateRange = DateRange(startDate: startDate.startOf(component: .day), endDate: endDate.endOf(component: .day), stepUnits: .day)
            let dates = dateRange.map({ $0 }) + [endDate.endOf(component: .day)]
            return (true, dates)
        }
        return (false, [startDate, endDate])
    }

    // Invokes a callback on circadian event intervals.
    // This is an array of event endpoints where an endpoint
    // is a pair of NSDate and metabolic state (i.e.,
    // whether you are eating/fasting/sleeping/exercising).
    //
    // Conceptually, circadian events are intervals with a starting date
    // and ending date. We represent these endpoints (i.e., starting vs ending)
    // as consecutive array elements. For example the following array represents
    // an eating event (as two array elements) following by a sleeping event
    // (also as two array elements):
    //
    // [('2016-01-01 20:00', .Meal), ('2016-01-01 20:45', .Meal), ('2016-01-01 23:00', .Sleep), ('2016-01-02 07:00', .Sleep)]
    //
    public func fetchCircadianEventIntervals(_ startDate: Date = Date().startOfDay , endDate: Date = Date().endOfDay, noTruncation: Bool = false, completion: @escaping HMCircadianBlock) {
        typealias Event = (Date, CircadianEvent)
        typealias IEvent = (Double, CircadianEvent)

        let sleepTy = HKObjectType.categoryType(forIdentifier: HKCategoryTypeIdentifier.sleepAnalysis)!
        let workoutTy = HKWorkoutType.workoutType()

        // Note: we assume the decomposition returns sorted dates.
        let (useCaching, decomposedQueries) = decomposeCircadianDateRangeForCaching(startDate, endDate: endDate)

        let queryGroup = DispatchGroup()
        var queryResults: [Int: [Event]] = [:]
        var queryErrors: [Error?] = []

        _ = Date()

        let cacheExpiryDate = Date() + 1.months

        for queryIndex in 1..<decomposedQueries.count {
            queryGroup.enter()
            let startDate = decomposedQueries[queryIndex-1]
            let endDate = decomposedQueries[queryIndex]

            let datePredicate = HKQuery.predicateForSamples(withStart: startDate, end: endDate, options: HKQueryOptions())
            let typesAndPredicates = [sleepTy: datePredicate, workoutTy: datePredicate]

            // Fetch HealthKit sleep and workout samples matching the requested data range.
            // Note the workout samples include meal events since we encode these as preparation
            // and recovery workouts.
            // We create event endpoints from the resulting samples.

            let runQuery : (@escaping([Event], Error?) -> Void) -> Void = { runCompletion in
                self.fetchSamples(typesAndPredicates) { (events, error) -> Void in

                    guard error == nil && !events.isEmpty else {
                        return
                    }

                    // Fetch samples returns a dictionary that map a HKSampleType to an array of HKSamples.
                    // We use a flatmap operation to concatenate all samples across different HKSampleTypes.
                    //
                    // We truncate the start of event intervals to the startDate parameter.
                    //

                    //log.info("MCHM FCEI raw result \(queryIndex) / \(decomposedQueries.count) \(events)")

                    let extendedEvents = events.flatMap { (ty,vals) -> [Event]? in
                        switch ty {
                        case is HKWorkoutType:
                            // Workout samples may be meal or exercise events.
                            // We turn each event into an array of two elements, indicating
                            // the start and end of the event.
                            return vals.flatMap { s -> [Event] in
                                let st = s.startDate
                                let en = s.endDate
                                guard let v = s as? HKWorkout else { return [] }
                                switch v.workoutActivityType {
                                case HKWorkoutActivityType.preparationAndRecovery:
                                    if let meta = v.metadata, let mealStr = meta["Meal Type"] as? String, let mealType = MealType(rawValue: mealStr) {
                                        return [(st as Date, .meal(mealType: mealType)), (en as Date, .meal(mealType: mealType))]
                                    }
                                    return []

                                default:
                                    return [(st as Date, .exercise(exerciseType: v.workoutActivityType)), (en as Date, .exercise(exerciseType: v.workoutActivityType))]
                                }
                            }

                        case is HKCategoryType:
                            // Convert sleep samples into event endpoints.
                            guard ty.identifier == HKCategoryTypeIdentifier.sleepAnalysis.rawValue else {
                                return nil
                            }
                            return vals.flatMap { s -> [Event] in return [(s.startDate as Date, .sleep), (s.endDate as Date, .sleep)] }

                        default:
                            return nil
                        }
                    }

                    // Sort event endpoints by their occurrence time.
                    // This sorts across all event types (sleep, eat, exercise).
                    runCompletion(extendedEvents.joined().sorted { (a,b) in return a.0 < b.0 }, error)
                }
            }

            if useCaching {
                let cacheKey = startDate.startOf(component: .day).weekdayName
                circadianCache.setObject(forKey: cacheKey, cacheBlock: { success, failure in
                    runQuery { (events, error) in
                        if let nserror = error as NSError? {
                            failure(nserror) } else {
                            success(MCCircadianEventArray(events: events), .date(cacheExpiryDate))
                        }
                    }
                }, completion: { object, isLoadedFromCache, error in

                    guard error == nil else {
                        queryErrors.append(error)
                        queryGroup.leave()
                        return
                    }
                    queryResults[queryIndex] = object?.events ?? []
                    queryGroup.leave()
                })
            } else {
                runQuery { (events, error) in
                    guard error == nil else {
                        queryErrors.append(error)
                        queryGroup.leave()
                        return
                    }

                    queryResults[queryIndex] = events
                    queryGroup.leave()
                }
            }
        }

        queryGroup.notify(queue: DispatchQueue.global(qos:.default)) {

            guard queryErrors.isEmpty else {
                completion([], queryErrors.first!)
                return
            }

            var sortedEvents: [Event] = []
            var mergeError: Error! = nil
            for i in 1..<decomposedQueries.count {
                if let events = queryResults[i] {
                    let cleanedEvents: [Event] = events.enumerated().flatMap { (index, eventEdge) in
                        if index % 2 == 0 {
                            // Drop the event if its interval end is strictly before the start date of interest.
                            if events[index+1].0 < startDate { return nil }

                                // Drop the event if its interval start is equal to or after the end date of interest.
                            else if endDate <= eventEdge.0 { return nil }

                                // Truncate the event if its interval start is before our start date of interest.
                            else if eventEdge.0 < startDate { return noTruncation ? eventEdge : (startDate, eventEdge.1) }

                            return eventEdge
                        }

                            // Drop the event if its interval end is strictly before the start date of interest.
                        else if eventEdge.0 < startDate { return nil }

                            // Truncate the event if its interval end is after our end date of interest.
                        else if endDate <= eventEdge.0 { return noTruncation ? eventEdge : (endDate, eventEdge.1) }

                        return eventEdge
                    }
                    sortedEvents.append(contentsOf: cleanedEvents)
                } else {
                    let msg = "No circadian events found for decomposed query \(i)"
                    mergeError = NSError(domain: HMErrorDomain, code: 1048576, userInfo: [NSLocalizedDescriptionKey: msg])
                    break
                }
            }

            guard mergeError == nil && !sortedEvents.isEmpty else {
                completion([], mergeError)
                return
            }

            // Up to this point the endpoint array does not contain any fasting events
            // since these are implicitly any interval where no other meal/sleep/exercise events occurs.
            // The following code creates explicit fasting events, so that the endpoint array
            // fully covers the [startDate, endDate) interval provided as parameters.
            let epsilon = 1.seconds

            // Create a "final" fasting event to cover the time period up to the endDate parameter.
            // This handles if the last sample occurs at exactly the endDate.
            let lastev = sortedEvents.last ?? sortedEvents.first!
            let lst = lastev.0 == endDate ? [] : [(lastev.0, CircadianEvent.fast), (endDate, CircadianEvent.fast)]

            // We create explicit fasting endpoints by folding over all meal/sleep/exercise endpoints.
            // The accumulated state is:
            // i. an endpoint array, which is returned as the result of the loop.
            // ii. a boolean indicating whether the current event is the start of an event interval.
            //     Thus (assuming 0-based arrays) even-numbered elements are interval starts, and
            //     odd-numbered elements are interval ends.
            // iii. the previous element in the loop.
            //
            let initialAccumulator : ([Event], Bool, Event?) = ([], true, nil)
            let endpointArray = sortedEvents.reduce(initialAccumulator, { (acc, event) in
                let eventEndpointDate = event.0
                let eventMetabolicState = event.1

                let resultArray = acc.0
                let eventIsIntervalStart = acc.1
                let prevEvent = acc.2

                let nextEventAsIntervalStart = !acc.1

                guard prevEvent != nil else {
                    // Skip prefix indicates whether we should add a fasting interval before the first event.
                    let skipPrefix = eventEndpointDate == startDate || startDate == Date.distantPast
                    let newResultArray = (skipPrefix ? [event] : [(startDate, CircadianEvent.fast), (eventEndpointDate, CircadianEvent.fast), event])
                    return (newResultArray, nextEventAsIntervalStart, event)
                }

                let prevEventEndpointDate = prevEvent?.0

                if (eventIsIntervalStart && prevEventEndpointDate == eventEndpointDate) {
                    // We skip adding any fasting event between back-to-back events.
                    // To do this, we check if the current event starts an interval, and whether
                    // the start date for this interval is the same as the end date of the previous interval.
                    let newResult = resultArray + [(eventEndpointDate + epsilon, eventMetabolicState)]
                    return (newResult, nextEventAsIntervalStart, event)
                } else if eventIsIntervalStart {
                    // This event endpoint is a starting event that has a gap to the previous event.
                    // Thus we fill in a fasting event in between.
                    // We truncate any events that last more than 24 hours to last 24 hours.

                    let newResult = resultArray + []
                    return (newResult, nextEventAsIntervalStart, event)
                } else {
                    // This endpoint is an interval ending event.
                    // Thus we add the endpoint to the result array.
                    return (resultArray + [event], nextEventAsIntervalStart, event)
                }
            }).0 + lst  // Add the final fasting event to the event endpoint array.

            completion(endpointArray, nil)
        }
    }

    // A filter-aggregate query template.
    public func fetchAggregatedCircadianEvents<T,U>(_ startDate: Date, endDate: Date, predicate: ((Date, CircadianEvent) -> Bool)? = nil,
                                               aggregator: @escaping ((T, (Date, CircadianEvent)) -> T),
                                               initialAccum: T, initialResult: U,
                                               final: @escaping ((T) -> U),
                                               completion: @escaping (U, _ error: Error?) -> Void) {
        fetchCircadianEventIntervals(Date.distantPast) { (intervals, error) in
            guard error == nil else {
                completion(initialResult, error)
                return
            }

            let filtered = predicate == nil ? intervals : intervals.filter(predicate!)
            let accum = filtered.reduce(initialAccum, aggregator)
            completion(final(accum), nil)
        }
    }

    // Time-restricted version of the above function.
    public func fetchAggregatedCircadianEvents<T,U>(predicate: ((Date, CircadianEvent) -> Bool)? = nil,
                                               aggregator: @escaping ((T, (Date, CircadianEvent)) -> T),
                                               initialAccum: T, initialResult: U,
                                               final: @escaping ((T) -> U),
                                               completion:  @escaping (U, _ error: Error?) -> Void) {
        fetchCircadianEventIntervals(Date.distantPast, endDate: Date.distantFuture) { (intervals, error) in
            guard error == nil else {
                completion(initialResult, error)
                return
            }

            let filtered = predicate == nil ? intervals : intervals.filter(predicate!)
            let accum = filtered.reduce(initialAccum, aggregator)
            completion(final(accum), nil)
        }
    }

    // Compute total eating times per day by filtering and aggregating over meal events.
    open func fetchEatingTimes(_ startDate: Date = Date().startOfDay, endDate: Date = Date(), completion:  @escaping HMCircadianAggregateBlock) {
        // Accumulator:
        // i. boolean indicating whether the current endpoint starts an interval.
        // ii. an NSDate indicating when the previous endpoint occurred.
        // iii. a dictionary of accumulated eating times per day.
        typealias Accum = (Bool, Date?, [Date: Double])

        let aggregator : (Accum, (Date, CircadianEvent)) -> Accum = { (acc, e) in
            let startOfInterval = acc.0
            let prevIntervalEndpointDate = acc.1
            var eatingTimesByDay = acc.2
            if !startOfInterval && prevIntervalEndpointDate != nil {
                switch e.1 {
                case .meal:
                    let day = prevIntervalEndpointDate?.startOf(component: .day)
                    let nEat = (eatingTimesByDay[day!] ?? 0.0) + e.0.timeIntervalSince(prevIntervalEndpointDate!)
                    eatingTimesByDay.updateValue(nEat, forKey: day!)
                    return (!startOfInterval, e.0, eatingTimesByDay)
                default:
                    return (!startOfInterval, e.0, eatingTimesByDay)
                }
            }
            return (!startOfInterval, e.0, eatingTimesByDay)
        }
        let initial : Accum = (true, nil, [:])
        let final : ((Accum) -> [(Date, Double)]) = { acc in
            let eatingTimesByDay = acc.2
            return eatingTimesByDay.sorted { (a,b) in return a.0 < b.0 }
        }

        if startDate == nil && endDate == nil {
            fetchAggregatedCircadianEvents(predicate: nil, aggregator: aggregator, initialAccum: initial, initialResult: [], final: final, completion: completion)
        } else {
            fetchAggregatedCircadianEvents(startDate, endDate: endDate,
                                           predicate: nil, aggregator: aggregator,
                                           initialAccum: initial, initialResult: [], final: final, completion: completion)
        }
    }

    // Compute max fasting times per day by filtering and aggregating over everything other than meal events.
    // This stitches fasting events together if they are sequential (i.e., one ends while the other starts).
    open func fetchMaxFastingTimes(_ startDate: NSDate? = nil, endDate: NSDate? = nil, completion: @escaping HMCircadianAggregateBlock) {
        // Accumulator:
        // i. boolean indicating whether the current endpoint starts an interval.
        // ii. start of this fasting event.
        // iii. the previous event.
        // iv. a dictionary of accumulated fasting intervals.
        typealias Accum = (Bool, Date?, Date?, [Date: Double])

        let predicate : (Date, CircadianEvent) -> Bool = { (_, event) in
            switch event {
            case .exercise, .fast, .sleep:
                return true
            default:
                return false
            }
        }

        let aggregator : (Accum, (Date, CircadianEvent)) -> Accum = { (acc, e) in
            var byDay = acc.3
            let (startOfInterval, prevFast, prevEvt) = (acc.0, acc.1, acc.2)
            var nextFast = prevFast
            if startOfInterval && prevFast != nil && prevEvt != nil && e.0 != prevEvt {
                let fastStartDay = prevFast?.startOf(component: .day)
                let duration = prevEvt?.timeIntervalSince(prevFast!)
                let currentMax = byDay[fastStartDay!] ?? duration
                byDay.updateValue((currentMax! >= duration! ? currentMax : duration)!, forKey: fastStartDay!)
                nextFast = e.0
            } else if startOfInterval && prevFast == nil {
                nextFast = e.0
            }
            return (!startOfInterval, nextFast, e.0, byDay)
        }

        let initial : Accum = (true, nil, nil, [:])
        let final : (Accum) -> [(Date, Double)] = { acc in
            var byDay = acc.3
            if let finalFast = acc.1, let finalEvt = acc.2 {
                if finalFast != finalEvt {
                    let fastStartDay = finalFast.startOf(component: .day)
                    let duration = finalEvt.timeIntervalSince(finalFast)
                    let currentMax = byDay[fastStartDay] ?? duration
                    byDay.updateValue(currentMax >= duration ? currentMax : duration, forKey: fastStartDay)
                }
            }
            return byDay.sorted { (a,b) in return a.0 < b.0 }
        }

        if startDate == nil && endDate == nil {
            fetchAggregatedCircadianEvents(predicate: predicate, aggregator: aggregator, initialAccum: initial, initialResult: [], final: final, completion: completion)
        } else {
            fetchAggregatedCircadianEvents(startDate as Date? ?? Date.distantPast, endDate: endDate as Date? ?? Date(),
                                           predicate: predicate, aggregator: aggregator,
                                           initialAccum: initial, initialResult: [], final: final, completion: completion)
        }
    }

    // Computes the number of days in the last year that have at least one sample, for the given types.
    // TODO: cache invalidation in observer query.
    public func fetchSampleCollectionDays(_ sampleTypes: [HKSampleType], completion: @escaping ([HKSampleType:Int], Error?) -> Void) {
        var someError: Error? = nil
        let group = DispatchGroup()
        var results : [HKSampleType:Int] = [:]

        let period : HealthManagerStatisticsRangeType = .year
        let (predicate, _, _, _) = periodAggregation(period)

        for sampleType in sampleTypes {


            group.enter()
            let type = sampleType.identifier == HKCorrelationTypeIdentifier.bloodPressure.rawValue ? HKQuantityTypeIdentifier.bloodPressureSystolic.rawValue : sampleType.identifier
            let proxyType = sampleType.identifier == type ? sampleType : HKObjectType.quantityType(forIdentifier: HKQuantityTypeIdentifier(rawValue: type))!

            let aggOp = proxyType.aggregationOptions
            let keyPrefix = "\(type)_cd"
            let key = getPeriodCacheKey(keyPrefix, aggOp: aggOp, period: period)

            aggregateCache.setObject(forKey:key, cacheBlock: { success, failure in
                // This caches a singleton array by aggregating over all samples for the year.
                let doCache : ([MCSample], Error?) -> Void = { (samples, error) in
                    guard error == nil else {
                        failure(error as NSError?)
                        return
                    }
                    let agg = self.aggregateSamplesManually(proxyType, aggOp: aggOp, samples: samples)
                    success(MCAggregateArray(aggregates: [agg]), .date(self.getCacheExpiry(period)))
                }

                self.fetchAggregatesOfType(proxyType, predicate: predicate, aggUnit: .day, aggOp: aggOp) {
                    self.queryResultAsSamples($0, error: $1) { doCache($0, $1) }
                }
            }, completion: {object, isLoadedFromCache, error in
                guard error == nil else {
                    someError = error
                    results.updateValue(0, forKey: sampleType)
                    group.leave()
                    return
                }

                if let aggArray = object {
                    if aggArray.aggregates.count > 0 {
                        results.updateValue(aggArray.aggregates[0].count(), forKey: sampleType)
                    } else {
                        results.updateValue(0, forKey: sampleType)
                    }
                    group.leave()
                } else {
                    results.updateValue(0, forKey: sampleType)
                    group.leave()
                }
            })
        }

        group.notify(queue: DispatchQueue.global(qos:.background)) {
            completion(results, someError)
        }
    }

    // Fetches summed circadian event durations, grouped according the the given function,
    // and within the specified start and end date.
    open func fetchCircadianDurationsByGroup<G: Hashable>(
        _ tag: String, startDate: Date, endDate: Date,
        predicate: ((Date, CircadianEvent) -> Bool)? = nil,
        transform: ((Double) -> Double)? = nil,
        groupBy: @escaping ((Date, CircadianEvent) -> G),
        completion: @escaping ([G:Double], Error?) -> Void) {
        // Accumulator:
        // i. boolean indicating whether the current endpoint starts an interval.
        // ii. the previous event.
        // iii. a dictionary of accumulated durations per group.
        typealias Accum = (Bool, Date?, [G:Double])

        let aggregator : (Accum, (Date, CircadianEvent)) -> Accum = { (acc, e) in
            var partialAgg = acc.2
            let (startOfInterval, prevEvtDate) = (acc.0, acc.1)
            let groupKey = groupBy(e.0, e.1)

            if !startOfInterval && prevEvtDate != nil {
                // Accumulate the interval duration for the current category.
                let incr = transform == nil ? e.0.timeIntervalSince(prevEvtDate!) : transform!(e.0.timeIntervalSince(prevEvtDate!))
                let nDur = (partialAgg[groupKey] ?? 0.0) + incr
                partialAgg.updateValue(nDur, forKey: groupKey)
            }
            return (!startOfInterval, e.0, partialAgg)
        }

        let initial : Accum = (true, nil, [:])
        let final : ((Accum) -> [G:Double]) = { return $0.2 }

        fetchAggregatedCircadianEvents(startDate, endDate: endDate, predicate: predicate, aggregator: aggregator,
                                       initialAccum: initial, initialResult: [:], final: final, completion: completion)
    }

    // General purpose fasting variability query, aggregating durations according to the given calendar unit.
    // This uses a one-pass variance/stddev calculation to finalize the resulting durations.
    open func fetchFastingVariability(_ startDate: Date, endDate: Date, aggUnit: Calendar.Component,
                                      completion: @escaping (_ variability: Double, _ error: Error?) -> Void) {
        let predicate: ((Date, CircadianEvent) -> Bool) = { (_, event) in
            switch event {
            case .exercise, .fast, .sleep:
                return true
            default:
                return false
            }
        }

        let unitDuration : Double = durationOfCalendarUnitInSeconds(aggUnit)
        let truncateToAggUnit : (Double) -> Double = { return min($0, unitDuration) }

        let group : (Date, CircadianEvent) -> Date = { (date, _) in  return date.startOf(component: aggUnit) }

        fetchCircadianDurationsByGroup("FV", startDate: startDate, endDate: endDate, predicate: predicate, transform: truncateToAggUnit, groupBy: group) {
            (table, error) in
            guard error == nil else {
                completion(0.0, error)
                return
            }
            // One pass variance calculation.
            // State: [n, mean, M2]
            var st: [Double] = [0.0, 0.0, 0.0]
            table.forEach { v in
                st[0] += 1
                let delta = v.1 - st[1]
                st[1] += delta/st[0]
                st[2] += delta * (v.1 - st[1])
            }
            let variance = st[0] > 1.0 ? ( st[2] / (st[0] - 1.0) ) : 0.0
            let stddev = variance > 0.0 ? sqrt(variance) : 0.0
            completion(stddev, error)
        }
    }


    open func fetchWeeklyFastingVariability(_ startDate: Date = Date().prevMonth, endDate: Date = Date(),
                                            completion: @escaping (_ variability: Double, _ error: Error?) -> Void) {
        fetchFastingVariability(startDate, endDate: endDate, aggUnit: .weekOfYear) {
            completion($0, $1)
        }
    }

    open func fetchDailyFastingVariability(_ startDate: Date = Date().prevMonth, endDate: Date = Date(),
                                           completion: @escaping (_ variability: Double, _ error: Error?) -> Void) {
        fetchFastingVariability(startDate, endDate: endDate, aggUnit: .day) {
            completion($0, $1)
        }
    }

    // Returns total time spent fasting and non-fasting in the last week
    open func fetchWeeklyFastState(_ completion: @escaping (_ fast: Double, _ nonFast: Double, _ error: Error?) -> Void) {
        let group : (Date, CircadianEvent) -> Int = { (_, event) in
            switch event {
            case .exercise, .sleep, .fast:
                return 0

            case .meal:
                return 1
            }
        }
        let queryStartTime = Date()
        fetchCircadianDurationsByGroup("WFS", startDate: Date().prevMonth, endDate: queryStartTime, groupBy: group) { (categories, error) in
            guard error == nil else {
                completion(0.0, 0.0, error)
                return
            }
            completion(categories[0] ?? 0.0, categories[1] ?? 0.0, error)
        }
    }

    // Returns total time spent fasting while sleeping and fasting while awake in the last week
    open func fetchWeeklyFastType(_ completion: @escaping (_ fastSleep: Double, _ fastAwake: Double, _ error: Error?) -> Void) {
        let predicate: ((Date, CircadianEvent) -> Bool) = { (_, event) in
            switch event {
            case .exercise, .fast, .sleep:
                return true
            default:
                return false
            }
        }

        let group : (Date, CircadianEvent) -> Int = { (_, event) in
            switch event {
            case .sleep:
                return 0
            case .exercise, .fast:
                return 1
            default:
                return 2
            }
        }

        fetchCircadianDurationsByGroup("WFT", startDate: Date().prevMonth, endDate: Date(), predicate: predicate, groupBy: group) { (categories, error) in
            guard error == nil else {
                completion(0.0, 0.0, error)
                return
            }
            completion(categories[0] ?? 0.0, categories[1] ?? 0.0, error)
        }
    }

    // Returns total time spent eating and exercising in the last week
    open func fetchWeeklyEatAndExercise(_ completion: @escaping (_ eatingTime: Double, _ exerciseTime: Double, _ error: Error?) -> Void) {
        let predicate: ((Date, CircadianEvent) -> Bool) = { (_, event) in
            switch event {
            case .exercise, .meal:
                return true
            default:
                return false
            }
        }

        let group : (Date, CircadianEvent) -> Int = { (_, event) in
            switch event {
            case .meal:
                return 0
            case .exercise:
                return 1
            default:
                return 2
            }
        }

        fetchCircadianDurationsByGroup("WEE", startDate: Date().prevMonth, endDate: Date(), predicate: predicate, groupBy: group) { (categories, error) in
            guard error == nil else {
                completion(0.0, 0.0, error)
                return
            }
            completion(categories[0] ?? 0.0, categories[1] ?? 0.0, error)
        }
    }

    open func correlateWithFasting(_ sortFasting: Bool, type: HKSampleType, predicate: NSPredicate? = nil, completion:  @escaping HMFastingCorrelationBlock) {
        var results1: [MCSample]?
        var results2: [(Date, Double)]?

        func intersect(_ samples: [MCSample], fasting: [(Date, Double)]) -> [(Date, Double, MCSample)] {
            var output:[(Date, Double, MCSample)] = []
            var byDay: [Date: Double] = [:]
            fasting.forEach { f in
                let start = f.0.startOf(component: .day)
                byDay.updateValue((byDay[start] ?? 0.0) + f.1, forKey: start)
            }

            samples.forEach { s in
                let start = s.startDate.startOf(component: .day)
                if let match = byDay[start] { output.append((start, match, s)) }
            }
            return output
        }

        let group = DispatchGroup()
        group.enter()
        fetchStatisticsOfType(type, predicate: predicate!) { (results, error) -> Void in
            guard error == nil else {
                completion([], error)
                group.leave()
                return
            }
            results1 = results
            group.leave()
        }
        group.enter()
        fetchMaxFastingTimes { (results, error) -> Void in
            guard error == nil else {
                completion([], error)
                group.leave()
                return
            }
            results2 = results
            group.leave()
        }

        group.notify(queue: DispatchQueue.global(qos:.background)) {
            guard !(results1 == nil || results2 == nil) else {
                let desc = results1 == nil ? (results2 == nil ? "LHS and RHS" : "LHS") : "RHS"
                let err = NSError(domain: HMErrorDomain, code: 1048576, userInfo: [NSLocalizedDescriptionKey: "Invalid \(desc) statistics"])
                completion([], err)
                return
            }
            var zipped = intersect(results1!, fasting: results2!)
            zipped.sort { (a,b) in return ( sortFasting ? a.1 < b.1 : a.2.numeralValue! < b.2.numeralValue! ) }
            completion(zipped, nil)
        }
    }

    // MARK as Error? : - Miscellaneous queries
    open func getOldestSampleDateForType(_ type: HKSampleType, completion: @escaping (Date?) -> ()) {
        fetchSamplesOfType(type, predicate: nil, limit: 1) { (samples, error) in
            guard error == nil else {
                completion(nil)
                return
            }
            completion((samples.isEmpty ? Date() as Date : samples[0].startDate) as Date)
        }
    }

    // MARK: - Writing into HealthKit
    open func saveSample(_ sample: HKSample, completion: @escaping (Bool, Error?) -> Void) {
        healthKitStore.save(sample, withCompletion: completion)
    }

    open func saveSamples(_ samples: [HKSample], completion: @escaping (Bool, Error?) -> Void) {
        healthKitStore.save(samples, withCompletion: completion)
    }

    open func saveSleep(_ startDate: Date, endDate: Date, metadata: NSDictionary, completion: ( (Bool, Error?) -> Void)!) {
        let type = HKObjectType.categoryType(forIdentifier: HKCategoryTypeIdentifier.sleepAnalysis)!
        let sample = HKCategorySample(type: type, value: HKCategoryValueSleepAnalysis.asleep.rawValue, start: startDate, end: endDate, metadata: metadata as? [String : Any])

        healthKitStore.save(sample, withCompletion: { (success, error) -> Void in
            if( error != nil  ) { completion(success,error) }
            else { completion(success,nil) }
        })
    }

    open func saveWorkout(_ startDate: Date, endDate: Date, activityType: HKWorkoutActivityType, distance: Double, distanceUnit: HKUnit, kiloCalories: Double, metadata:NSDictionary, completion: ( (Bool, Error?) -> Void)!) {
        let distanceQuantity = HKQuantity(unit: distanceUnit, doubleValue: distance)
        let caloriesQuantity = HKQuantity(unit: HKUnit.kilocalorie(), doubleValue: kiloCalories)

        let workout = HKWorkout(activityType: activityType,
                                start: startDate,
                                end: endDate,
                                duration: abs(endDate.timeIntervalSince(startDate)),
                                totalEnergyBurned: caloriesQuantity,
                                totalDistance: distanceQuantity,
                                metadata: metadata as! [String:String])

        healthKitStore.save(workout, withCompletion: { (success, error) -> Void in
            if( error != nil  ) { completion(success,error) }
            else { completion(success,nil) }
        })
    }

    open func saveRunningWorkout(_ startDate: Date, endDate: Date, distance:Double, distanceUnit: HKUnit, kiloCalories: Double, metadata: NSDictionary, completion:  ( (Bool, Error?) -> Void)!) {
        saveWorkout(startDate, endDate: endDate,
                    activityType: HKWorkoutActivityType.running,
                    distance: distance,
                    distanceUnit: distanceUnit,
                    kiloCalories: kiloCalories,
                    metadata: metadata,
                    completion: completion)
    }

    open func saveCyclingWorkout(_ startDate: Date, endDate: Date, distance:Double, distanceUnit: HKUnit, kiloCalories: Double, metadata: NSDictionary, completion: ( (Bool, Error?) -> Void)!) {
        saveWorkout(startDate, endDate: endDate,
                    activityType: HKWorkoutActivityType.cycling,
                    distance: distance,
                    distanceUnit: distanceUnit,
                    kiloCalories: kiloCalories,
                    metadata: metadata,
                    completion: completion)
    }

    open func saveSwimmingWorkout(_ startDate: Date, endDate: Date, distance:Double, distanceUnit: HKUnit, kiloCalories: Double, metadata: NSDictionary, completion: ( (Bool, Error?) -> Void)!) {
        saveWorkout(startDate, endDate: endDate,
                    activityType: HKWorkoutActivityType.swimming,
                    distance: distance,
                    distanceUnit: distanceUnit,
                    kiloCalories: kiloCalories,
                    metadata: metadata,
                    completion: completion)
    }

    open func savePreparationAndRecoveryWorkout(_ startDate: Date, endDate: Date, distance:Double, distanceUnit: HKUnit, kiloCalories: Double, metadata: NSDictionary, completion: ( (Bool, Error?) -> Void)!) {
        saveWorkout(startDate, endDate: endDate,
                    activityType: HKWorkoutActivityType.preparationAndRecovery,
                    distance: distance,
                    distanceUnit: distanceUnit,
                    kiloCalories: kiloCalories,
                    metadata: metadata,
                    completion: completion)
    }

    public func deleteCircadianEvents(_ startDate: Date, endDate: Date, completion: @escaping (Error?) -> Void) {
        let withSourcePredicate: (NSPredicate) -> NSPredicate = { pred in
            return NSCompoundPredicate(andPredicateWithSubpredicates: [
                pred, HKQuery.predicateForObjects(from: HKSource.default())
                ])
        }

        let mealConjuncts = [
            HKQuery.predicateForWorkouts(with: .preparationAndRecovery),
            HKQuery.predicateForObjects(withMetadataKey: "Meal Type")
        ]
        let mealPredicate = NSCompoundPredicate(andPredicateWithSubpredicates: mealConjuncts)

        let circadianEventPredicates: NSPredicate = NSCompoundPredicate(orPredicateWithSubpredicates: [
            mealPredicate,
            HKQuery.predicateForWorkouts(with: .running),
            HKQuery.predicateForWorkouts(with: .cycling),
            HKQuery.predicateForWorkouts(with: .swimming),
            ])

        let sleepType = HKCategoryType.categoryType(forIdentifier: HKCategoryTypeIdentifier.sleepAnalysis)!
        let sleepPredicate = HKQuery.predicateForCategorySamples(with: .equalTo, value: HKCategoryValueSleepAnalysis.asleep.rawValue)

        let typesAndPredicates: [HKSampleType: NSPredicate] = [
            HKWorkoutType.workoutType(): withSourcePredicate(circadianEventPredicates),
            sleepType: withSourcePredicate(sleepPredicate)
        ]
        
        self.deleteSamples(startDate, endDate: endDate, typesAndPredicates: typesAndPredicates) { (deleted, error) in
            if error != nil {
                //                log.error("Failed to delete samples on the device, HealthKit may potentially diverge from the server.")
                //                log.error(error!.localizedDescription)
            }
            
            self.invalidateCircadianCache(startDate, endDate: endDate)
            completion(error)
        }
    }

    // MARK: - Removing samples from HealthKit
    
    public func deleteSamplesOfType(_ sampleType: HKSampleType, startDate: Date?, endDate: Date?, predicate: NSPredicate,
                                    withCompletion completion: @escaping (_ success: Bool, _ count: Int, _ error: Error?) -> Void)
    {
        let predWithInterval =
            startDate == nil && endDate == nil ?
                predicate :
                NSCompoundPredicate(andPredicateWithSubpredicates: [
                    predicate, HKQuery.predicateForSamples(withStart: startDate, end: endDate, options: HKQueryOptions())
                    ])

        self.healthKitStore.deleteObjects(of: sampleType, predicate: predWithInterval, withCompletion: completion)
    }
    
    public func deleteSamples(_ startDate: Date? = nil, endDate: Date? = nil, typesAndPredicates: [HKSampleType: NSPredicate],
                              completion: @escaping (_ deleted: Int, _ error: NSError?) -> Void)
    {
        let group = DispatchGroup()
        var numDeleted = 0
        
        typesAndPredicates.forEach { (type, predicate) -> () in
            group.enter()
            self.deleteSamplesOfType(type, startDate: startDate, endDate: endDate, predicate: predicate) {
                (success, count, error) in
                guard success && error == nil else {
//                    log.error("Could not delete samples for \(type.displayText)(\(success)): \(error)")
                    group.leave()
                    return
                }
                numDeleted += count
                group.leave()
            }
        }
        
        group.notify(queue: DispatchQueue.main) {
            // TODO: partial error handling, i.e., when a subset of the desired types fail in their queries.
            completion(numDeleted, nil)
        }
    }
    
    // MARK: - Cache invalidation
    func invalidateCircadianCache(_ startDate: Date, endDate: Date) {
        let dateRange = DateRange(startDate: startDate.startOf(component: .day), endDate: endDate.endOf(component: .day), stepUnits: .day)
        let dateSet = Set<Date>(dateRange)
        for date in dateSet {
            circadianCache.removeObject(forKey:date.intervalString(toDate: date))
        }
        NotificationCenter.default.post(name: NSNotification.Name(rawValue: HMDidUpdateCircadianEvents), object: self)
    }

    func invalidateMeasureCache(_ sampleTypeId: String) {
        if let task = measureNotifyTaskByType[sampleTypeId] { task?.cancel() }
        let task = Async.background(after: notifyInterval) {
            NotificationCenter.default.post(name: NSNotification.Name(rawValue: sampleTypeId), object: self)
        }
        measureNotifyTaskByType.updateValue(task, forKey: sampleTypeId)
    }

    public func invalidateCacheForUpdates(_ type: HKSampleType, added: [HKSample]? = nil) {
        let corelationBloodPressure = HKCorrelationTypeIdentifier.bloodPressure.rawValue
        let cacheType = (type.identifier == corelationBloodPressure) ? HKQuantityTypeIdentifier.bloodPressureSystolic.rawValue : type.identifier
        let cacheKeyPrefix = cacheType
        let expiredPeriods : [HealthManagerStatisticsRangeType] = [.week, .month, .year]
        var expiredKeys : [String]

        let minMaxKeys = expiredPeriods.map { self.getPeriodCacheKey(cacheKeyPrefix, aggOp: [.discreteMin, .discreteMax], period: $0) }
        let avgKeys = expiredPeriods.map { self.getPeriodCacheKey(cacheKeyPrefix, aggOp: .discreteAverage, period: $0) }

        if (cacheType == HKQuantityTypeIdentifier.bloodPressureSystolic.rawValue) {
            self.sampleCache.removeObject(forKey:  corelationBloodPressure)
        }
        self.sampleCache.removeObject(forKey:type.identifier)
        if let task = anyMeasureNotifyTask { task.cancel() }
        anyMeasureNotifyTask = Async.background(after: notifyInterval) {
            NotificationCenter.default.post(name: NSNotification.Name(rawValue: HMDidUpdateAnyMeasures), object: self)
        }

        if measureInvalidationsByType.contains(cacheType) { invalidateMeasureCache(cacheType) }

        if cacheType == HKQuantityTypeIdentifier.heartRate.rawValue || cacheType == HKQuantityTypeIdentifier.uvExposure.rawValue {
            expiredKeys = minMaxKeys
        } else if cacheType == HKQuantityTypeIdentifier.bloodPressureSystolic.rawValue {
            expiredKeys = minMaxKeys
        } else {
            expiredKeys = avgKeys
        }
        expiredKeys.forEach {
            self.aggregateCache.removeObject(forKey:$0)
        }
        
        if added != nil {
            let z: (Date?, Date?) = (nil, nil)
            let minMaxDates = added!.reduce(z, { (acc, s) in
                return (min(acc.0 ?? s.startDate, s.startDate), max(acc.1 ?? s.endDate, s.endDate))
            })
            
            if minMaxDates.0 != nil && minMaxDates.1 != nil {
                invalidateCircadianCache(minMaxDates.0!, endDate: minMaxDates.1!)
            }
        }
    }
}

// Helper struct for iterating over date ranges.
public struct DateRange : Sequence {
    
    var calendar: Calendar = Calendar(identifier: Calendar.Identifier.gregorian)
    
    var startDate: Date
    var endDate: Date
    var stepUnits: Calendar.Component
    var stepValue: Int
    
    var currentStep: Int = 0
    
    init(startDate: Date, endDate: Date, stepUnits: Calendar.Component, stepValue: Int = 1) {
        self.startDate = startDate
        self.endDate = endDate
        self.stepUnits = stepUnits
        self.stepValue = stepValue
    }
    
    public func makeIterator() -> Iterator {
        return Iterator(range: self)
    }
    
    public struct Iterator: IteratorProtocol {
        
        var range: DateRange
        
        mutating public func next() -> Date? {
            if range.currentStep == 0 { range.currentStep += 1; return range.startDate }
            else {
                if let nextDate = range.calendar.date(byAdding: .day, value: range.stepValue, to: range.startDate) {
                    range.currentStep += 1
                    if range.endDate <= nextDate {
                        return nil
                    } else {
                        range.startDate = nextDate
                        return nextDate
                    }
                }
                return nil
            }
        }
    }
}
