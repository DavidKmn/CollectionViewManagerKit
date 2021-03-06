//
//  HeckelDiff.swift
//  CollectionManager
//
//  Created by David on 01/11/2018.
//  Copyright © 2018 David. All rights reserved.
//

import Foundation

internal func diff(
    old: [DiffableModel],
    new: [DiffableModel], diffingAlgorithm: DiffingAlgorithm = HeckelDiff()) -> [Change<DiffableModel>] {
    
    if let changes = diffingAlgorithm.performPreprocessing(old: old, new: new) {
        return changes
    }
    
    return diffingAlgorithm.performDiff(old: old, new: new)
}


class HeckelDiff: DiffingAlgorithm {
    // OC and NC value choices
    enum Counter {
        case zero
        case one
        case many
        
        mutating func increment() {
            switch self {
            case .zero:
                self = .one
            case .one:
                self = .many
            case .many:
                break
            }
        }
    }
    
    // The Symbol Table -> Stores 3 entries for each line
    class SymbolTableEntry: Equatable {
        
        var oldCounter: Counter = .zero
        var newCounter: Counter = .zero
        var oldLineReferenceIndexes: [Int] = []
        
        /// true if the symbol is available in both of the arrays
        var isInBoth: Bool {
            return !(oldCounter == .zero || newCounter == .zero)
        }
        
        
        static func == (lhs: HeckelDiff.SymbolTableEntry, rhs: HeckelDiff.SymbolTableEntry) -> Bool {
            return lhs.oldCounter == rhs.oldCounter && lhs.newCounter == rhs.newCounter && lhs.oldLineReferenceIndexes == rhs.oldLineReferenceIndexes
        }
    }
    
    // The arrays OA and NA have one entry for each line in their respective files, O and N.
    enum ArrayEntry: Equatable {
        case pointer(SymbolTableEntry)
        case index(Int)
        
        static func == (lhs: HeckelDiff.ArrayEntry, rhs: HeckelDiff.ArrayEntry) -> Bool {
            switch (lhs, rhs) {
            case (.pointer(let l), .pointer(let r)):
                return l == r
            case (.index(let l), .index(let r)):
                return l == r
            default: return false
            }
        }
    }
    
    /// - Parameters:
    ///   - old: The array to compare.
    ///   - new: The array to compare against.
    func performDiff(old: [DiffableModel], new: [DiffableModel]) -> [Change<DiffableModel>] {
        var symbolTable: [Int: SymbolTableEntry] = [:]
        
        var oldArray = [ArrayEntry]()
        var newArray = [ArrayEntry]()
        
        
        setupTable(forNew: new, table: &symbolTable, newArray: &newArray)
        setupTable(forOld: old, table: &symbolTable, oldArray: &oldArray)
        identifyUniqueEntries(newArray: &newArray, oldArray: &oldArray)
        performExpansionOfUniqueEntries(inDirection: .ascending, newArray: &newArray, oldArray: &oldArray)
        performExpansionOfUniqueEntries(inDirection: .descending, newArray: &newArray, oldArray: &oldArray)
        let changes = performLastPass(new: new, old: old, newArray: newArray, oldArray: oldArray)
        return changes
    }
    
    /// ## First Pass
    ///
    /// a. Each entry of array `new` is read in sequence
    /// b. An entry for each is created in the table, if it doesn't already exist
    /// c. `newCount` for the table entry is incremented
    /// d. `new[i]` is set to point to the table entry of index i
    private func setupTable(forNew new: [DiffableModel], table: inout [Int: SymbolTableEntry], newArray: inout [ArrayEntry]) {
        // Each line i of file N is read in sequence
        new.forEach { item in
            // Entry for each line i is created in the table, if it doesn't already exist
            let entry = table[item.primaryKeyValue] ?? SymbolTableEntry()
            // NC for the line's table entry is incremented
            entry.newCounter.increment()
            // NA[i] is set to point to the table entry of line i
            newArray.append(.pointer(entry))
            
            table[item.primaryKeyValue] = entry
        }
    }
    
    /// ## Second Pass
    ///
    /// a. Each entry of array `old` is read in sequence
    /// b. An entry for each is created in the table, if it doesn't already exist
    /// c. `oldCount` for the table entry is incremented
    /// d. Add a reference index for the position of the entry in old
    /// e. `old[i]` is set to point to the table entry of index i
    private func setupTable(forOld old: [DiffableModel], table: inout [Int: SymbolTableEntry], oldArray: inout [ArrayEntry]) {
        // Similar to first, but acts on files
        old.enumerated().forEach { (tuple) in
            let (index, item) = tuple
            
            // old
            let entry = table[item.primaryKeyValue] ?? SymbolTableEntry()
            // oldCounter
            entry.oldCounter.increment()
            // set to the line's number
            entry.oldLineReferenceIndexes.append(index)
            // oldArray
            oldArray.append(.pointer(entry))
            
            table[item.primaryKeyValue] = entry
        }
    }
    
    /// ## Third Pass
    ///
    /// a. We use Observation 1:
    /// > If a entry occurs only once in each array, then it must be the same entry, although it may have been moved.
    /// > We use this observation to locate unaltered entries that we subsequently exclude from further treatment.
    ///
    /// b. Using this, we only process the entries where `oldCount` == `newCount` == 1.
    ///
    /// c. As the entries between `old` and `new` "must be the same entry, although it may have been moved", we alter the table pointers to the number of the entry in the other array.
    ///
    /// d. We also locate unique virtual entries
    ///  - immediately before the first and
    ///  - immediately after the last
    private func identifyUniqueEntries(newArray: inout [ArrayEntry], oldArray: inout [ArrayEntry]) {
        newArray.enumerated().forEach { (indexOfNew, item) in
            if case .pointer(let entry) = item, entry.isInBoth {
                guard !(entry.oldLineReferenceIndexes.isEmpty) else { return }
                let indexOfOld = entry.oldLineReferenceIndexes.removeFirst()
                
                newArray[indexOfNew] = .index(indexOfOld)
                oldArray[indexOfOld] = .index(indexOfNew)
            }
        }
    }
    
    /// ## Fourth Pass
    ///
    /// a. We use Observation 2:
    /// > If a entry has been found to be unaltered, and the entries immediately adjacent to it in both arrays are identical, then these entries must be the same entry.
    /// > This information can be used to find blocks of unchanged entries.
    ///
    /// b. Using this, we process each entry in ascending order.
    ///
    /// c. If
    ///
    ///  - new[i] points to old[j], and
    ///  - new[i + 1] and old[j + 1] contain identical table entry pointers
    /// **then**
    ///  - old[j + 1] is set to entry i + 1, and
    ///  - old[i + 1] is set to entry j + 1
    /// &
    /// ## Fifth Pass
    ///
    /// Similar to fourth pass, except:
    ///
    /// It processes each entry in descending order
    /// It uses j - 1 and i - 1 instead of j + 1 and i + 1
    ///
    /// - Parameter direction: The direction to walk, ascending or descending
    private func performExpansionOfUniqueEntries(inDirection traversalDirection: TraversalDirection, newArray: inout [ArrayEntry], oldArray: inout [ArrayEntry]) {
        
        var i = traversalDirection.start(references: newArray)
        
        while traversalDirection.isValid(i: i, references: newArray) {
            if case .index(let j) = newArray[i], traversalDirection.isValid(i: j, references: oldArray) {
                if case .pointer(let new) = newArray[i + traversalDirection.step], case .pointer(let old) = oldArray[j + traversalDirection.step], new === old {
                    newArray[i + traversalDirection.step] = .index(j + traversalDirection.step)
                    oldArray[j + traversalDirection.step] = .index(i + traversalDirection.step)
                }
            }
            i += traversalDirection.step
        }
    }
    
    private func performLastPass(new: [DiffableModel], old: [DiffableModel], newArray: [ArrayEntry], oldArray: [ArrayEntry]) -> [Change<DiffableModel>] {
        
        var changes = [Change<DiffableModel>]()
        
        var deleteOffsets = Array(repeating: 0, count: old.count)
        var runningOffset = 0
        
        // Deleteions
        oldArray.enumerated().forEach { (index, item) in
            deleteOffsets[index] = runningOffset
            
            if case .pointer(_) = item {
                changes.append(.delete(index: index, item: old[index]))
                runningOffset += 1
            }
        }
        
        runningOffset = 0
        
        // Insertions, updatements/Updates, Moves
        newArray.enumerated().forEach { (newIndex, item) in
            switch item {
            case .pointer(_):
                // line i must be new -> Insertion
                changes.append(.insert(index: newIndex, item: new[newIndex]))
                runningOffset += 1
            case .index(let oldIndex):
                // updatement/Update
                if old[oldIndex].primaryKeyValue != new[newIndex].primaryKeyValue {
                    changes.append(.update(index: newIndex, item: new[newIndex]))
                }
                
                let deleteOffset = deleteOffsets[oldIndex]
                // The object is not at the expected position, so move it.
                if (oldIndex - deleteOffset + runningOffset) != newIndex {
                    changes.append(.move(from: oldIndex, to: newIndex, item: new[newIndex]))
                }
            }
        }
        return changes
    }
    
    /// An enumeration to specify the direction of the traversal of references.
    enum TraversalDirection {
        
        /// - ascending: Walk the references in ascending order.
        case ascending
        
        /// - descending: Walk the references in decending order.
        case descending
        
        /// The starting value of the walk.
        ///
        /// - Parameter references: The references which are being walked.
        /// - Returns: The start index.
        func start(references: [ArrayEntry]) -> Int {
            switch self {
            case .ascending:
                return 1
            case .descending:
                return references.count - 1
            }
        }
        
        /// The step increase when walking references.
        var step: Int {
            switch self {
            case .ascending:
                return 1
            case .descending:
                return -1
            }
        }
        
        /// Compare the index with the list of indexes to ensure it is valid.
        ///
        /// - Parameters:
        ///   - i: the index to validate
        ///   - references: The array of references, the count of these determines if the traversal is still valid.
        /// - Returns: true if the traversal is still valid.
        func isValid(i: Int, references: [ArrayEntry]) -> Bool {
            switch self {
            case .ascending:
                return i < references.count - 1
            case .descending:
                return i > 0
            }
        }
        
        /// Determine if the index is in range and can be continued.
        ///
        /// - Parameters:
        ///   - i: the index to validate
        ///   - references: The array of references, the count of these determines if the traversal is still valid.
        /// - Returns: true if the index is in range.
        func inRange(i: Int, references: [ArrayEntry]) -> Bool {
            switch self {
            case .ascending:
                return i + step < references.count
            case .descending:
                return i + step >= 0
            }
            
        }
        
    }
}
