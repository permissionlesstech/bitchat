//
// LRUCache.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation

/// Thread-safe LRU (Least Recently Used) cache implementation
final class LRUCache<Key: Hashable, Value> {
    private class Node {
        var key: Key
        var value: Value
        var prev: Node?
        var next: Node?
        
        init(key: Key, value: Value) {
            self.key = key
            self.value = value
        }
    }
    
    private let maxSize: Int
    private var cache: [Key: Node] = [:]
    private var head: Node?
    private var tail: Node?
    private let queue = DispatchQueue(label: "bitchat.lrucache", attributes: .concurrent)
    
    init(maxSize: Int) {
        self.maxSize = maxSize
    }
    
    func set(_ key: Key, value: Value) {
        queue.sync(flags: .barrier) {
            if let node = cache[key] {
                // Update existing value and move to front
                node.value = value
                moveToFront(node)
            } else {
                // Add new node
                let newNode = Node(key: key, value: value)
                cache[key] = newNode
                addToFront(newNode)
                
                // Remove oldest if over capacity
                if cache.count > maxSize {
                    if let tailNode = tail {
                        removeNode(tailNode)
                        cache.removeValue(forKey: tailNode.key)
                    }
                }
            }
        }
    }
    
    func get(_ key: Key) -> Value? {
        return queue.sync(flags: .barrier) {
            guard let node = cache[key] else { return nil }
            moveToFront(node)
            return node.value
        }
    }
    
    func contains(_ key: Key) -> Bool {
        return queue.sync {
            return cache[key] != nil
        }
    }
    
    func remove(_ key: Key) {
        queue.sync(flags: .barrier) {
            if let node = cache[key] {
                removeNode(node)
                cache.removeValue(forKey: key)
            }
        }
    }
    
    func removeAll() {
        queue.sync(flags: .barrier) {
            cache.removeAll()
            head = nil
            tail = nil
        }
    }
    
    var count: Int {
        return queue.sync {
            return cache.count
        }
    }
    
    var keys: [Key] {
        return queue.sync {
            return Array(cache.keys)
        }
    }
    
    // MARK: - Private Helpers
    
    private func addToFront(_ node: Node) {
        node.next = head
        node.prev = nil
        
        if let head = head {
            head.prev = node
        }
        
        head = node
        
        if tail == nil {
            tail = node
        }
    }
    
    private func removeNode(_ node: Node) {
        if let prev = node.prev {
            prev.next = node.next
        } else {
            head = node.next
        }
        
        if let next = node.next {
            next.prev = node.prev
        } else {
            tail = node.prev
        }
        
        node.prev = nil
        node.next = nil
    }
    
    private func moveToFront(_ node: Node) {
        guard node !== head else { return }
        removeNode(node)
        addToFront(node)
    }
}

// MARK: - Bounded Set

/// Thread-safe set with maximum size using LRU eviction
final class BoundedSet<Element: Hashable> {
    private let cache: LRUCache<Element, Bool>
    
    init(maxSize: Int) {
        self.cache = LRUCache(maxSize: maxSize)
    }
    
    func insert(_ element: Element) {
        cache.set(element, value: true)
    }
    
    func contains(_ element: Element) -> Bool {
        return cache.get(element) != nil
    }
    
    func remove(_ element: Element) {
        cache.remove(element)
    }
    
    func removeAll() {
        cache.removeAll()
    }
    
    var count: Int {
        return cache.count
    }
}