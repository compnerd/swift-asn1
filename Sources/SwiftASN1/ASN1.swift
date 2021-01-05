//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftCrypto open source project
//
// Copyright (c) 2019-2020 Apple Inc. and the SwiftCrypto project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of SwiftCrypto project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

/// ``ASN1`` defines a namespace that is used to store a number of helper methods and types.
public enum ASN1 { }

// MARK: - Parser Node
extension ASN1 {
    /// An ``ASN1ParserNode`` is a representation of a parsed ASN.1 TLV section.
    ///
    /// An ``ASN1ParserNode`` may be primitive, or may be composed of other ``ASN1ParserNode``s.
    /// In our representation, we keep track of this by storing a node "depth", which allows rapid forward and backward scans to hop over sections
    /// we're uninterested in.
    ///
    /// This type is not exposed to users of the API: it is only used internally for implementation of the user-level API.
    @usableFromInline
    struct ASN1ParserNode {
        /// The identifier.
        @usableFromInline
        var identifier: ASN1Identifier

        /// The depth of this node.
        @usableFromInline
        var depth: Int

        /// The encoded bytes for this complete ASN.1 object.
        @usableFromInline
        var encodedBytes: ArraySlice<UInt8>

        /// The data bytes for this node, if it is primitive.
        @usableFromInline
        var dataBytes: ArraySlice<UInt8>?

        @inlinable
        init(
            identifier: ASN1.ASN1Identifier,
            depth: Int,
            encodedBytes: ArraySlice<UInt8>,
            dataBytes: ArraySlice<UInt8>? = nil
        ) {
            self.identifier = identifier
            self.depth = depth
            self.encodedBytes = encodedBytes
            self.dataBytes = dataBytes
        }
    }
}

extension ASN1.ASN1ParserNode: Hashable { }

extension ASN1.ASN1ParserNode: Sendable { }

extension ASN1.ASN1ParserNode: CustomStringConvertible {
    @inlinable
    var description: String {
        return "ASN1.ASN1ParserNode(identifier: \(self.identifier), depth: \(self.depth), dataBytes: \(self.dataBytes?.count ?? 0))"
    }
}

// MARK: - Sequence, SequenceOf, and Set
extension ASN1 {
    /// Parse the node as an ASN.1 SEQUENCE.
    ///
    /// The "child" elements in the sequence will be exposed as an iterator to `builder`.
    ///
    /// - parameters:
    ///     - node: The ``ASN1Node`` to parse
    ///     - identifier: The ``ASN1/ASN1Identifier`` that the SEQUENCE is expected to have.
    ///     - builder: A closure that will be called with the collection of nodes within the sequence.
    @inlinable
    public static func sequence<T>(_ node: ASN1Node, identifier: ASN1.ASN1Identifier, _ builder: (inout ASN1.ASN1NodeCollection.Iterator) throws -> T) throws -> T {
        guard node.identifier == identifier, case .constructed(let nodes) = node.content else {
            throw ASN1Error.unexpectedFieldType
        }

        var iterator = nodes.makeIterator()

        let result = try builder(&iterator)

        guard iterator.next() == nil else {
            throw ASN1Error.invalidASN1Object
        }

        return result
    }

    /// Parse the node as an ASN.1 SEQUENCE OF.
    ///
    /// Constructs an array of `T` elements parsed from the sequence.
    ///
    /// - parameters:
    ///     - of: An optional parameter to express the type to decode.
    ///     - identifier: The ``ASN1/ASN1Identifier`` that the SEQUENCE OF is expected to have.
    ///     - rootNode: The ``ASN1Node`` to parse
    /// - returns: An array of elements representing the elements in the sequence.
    @inlinable
    public static func sequence<T: ASN1Parseable>(of: T.Type = T.self, identifier: ASN1.ASN1Identifier, rootNode: ASN1Node) throws -> [T] {
        guard rootNode.identifier == identifier, case .constructed(let nodes) = rootNode.content else {
            throw ASN1Error.unexpectedFieldType
        }

        return try nodes.map { try T(asn1Encoded: $0) }
    }

    /// Parse the node as an ASN.1 SEQUENCE OF.
    ///
    /// Constructs an array of `T` elements parsed from the sequence.
    ///
    /// - parameters:
    ///     - of: An optional parameter to express the type to decode.
    ///     - identifier: The ``ASN1/ASN1Identifier`` that the SEQUENCE OF is expected to have.
    ///     - nodes: An ``ASN1/ASN1NodeCollection/Iterator`` of nodes to parse.
    /// - returns: An array of elements representing the elements in the sequence.
    @inlinable
    public static func sequence<T: ASN1Parseable>(of: T.Type = T.self, identifier: ASN1.ASN1Identifier, nodes: inout ASN1.ASN1NodeCollection.Iterator) throws -> [T] {
        guard let node = nodes.next() else {
            // Not present, throw.
            throw ASN1Error.invalidASN1Object
        }

        return try sequence(of: T.self, identifier: identifier, rootNode: node)
    }

    /// Parse the node as an ASN.1 SET.
    ///
    /// The "child" elements in the sequence will be exposed as an iterator to `builder`.
    ///
    /// - parameters:
    ///     - node: The ``ASN1Node`` to parse
    ///     - identifier: The ``ASN1/ASN1Identifier`` that the SET is expected to have.
    ///     - builder: A closure that will be called with the collection of nodes within the set.
    @inlinable
    public static func set<T>(_ node: ASN1Node, identifier: ASN1.ASN1Identifier, _ builder: (inout ASN1.ASN1NodeCollection.Iterator) throws -> T) throws -> T {
        // Shhhh these two are secretly the same with identifier.
        return try sequence(node, identifier: identifier, builder)
    }
}

// MARK: - Optional explicitly tagged
extension ASN1 {
    /// Parses an optional explicitly tagged element.
    ///
    /// - parameters:
    ///     - nodes: The ``ASN1/ASN1NodeCollection/Iterator`` to parse this element out of.
    ///     - tagNumber: The number of the explicit tag.
    ///     - tagClass: The class of the explicit tag.
    ///     - builder: A closure that will be called with the node for the element, if the element is present.
    ///
    /// - returns: The result of `builder` if the element was present, or `nil` if it was not.
    @inlinable
    public static func optionalExplicitlyTagged<T>(_ nodes: inout ASN1.ASN1NodeCollection.Iterator, tagNumber: UInt, tagClass: ASN1.ASN1Identifier.TagClass, _ builder: (ASN1Node) throws -> T) throws -> T? {
        var localNodesCopy = nodes
        guard let node = localNodesCopy.next() else {
            // Node not present, return nil.
            return nil
        }

        let expectedNodeID = ASN1.ASN1Identifier(explicitTagWithNumber: tagNumber, tagClass: tagClass)
        assert(expectedNodeID.constructed)
        guard node.identifier == expectedNodeID else {
            // Node is a mismatch, with the wrong tag. Our optional isn't present.
            return nil
        }

        // We have the right optional, so let's consume it.
        nodes = localNodesCopy

        // We expect a single child.
        guard case .constructed(let nodes) = node.content else {
            // This error is an internal parser error: the tag above is always constructed.
            preconditionFailure("Explicit tags are always constructed")
        }

        var nodeIterator = nodes.makeIterator()
        guard let child = nodeIterator.next(), nodeIterator.next() == nil else {
            throw ASN1Error.invalidASN1Object
        }

        return try builder(child)
    }
}

// MARK: - Optional implicitly tagged
extension ASN1 {
    /// Parses an optional implicitly tagged element.
    ///
    /// - parameters:
    ///     - nodes: The ``ASN1/ASN1NodeCollection/Iterator`` to parse this element out of.
    ///     - tag: The implicit tag. Defaults to the default tag for the element.
    ///
    /// - returns: The parsed element, if it was present, or `nil` if it was not.
    @inlinable
    public static func optionalImplicitlyTagged<T: ASN1ImplicitlyTaggable>(_ nodes: inout ASN1.ASN1NodeCollection.Iterator, tag: ASN1Identifier = T.defaultIdentifier) throws -> T? {
        var localNodesCopy = nodes
        guard let node = localNodesCopy.next() else {
            // Node not present, return nil.
            return nil
        }

        guard node.identifier == tag else {
            // Node is a mismatch, with the wrong tag. Our optional isn't present.
            return nil
        }

        // We're good: pass the node on.
        return try T(asn1Encoded: &nodes, withIdentifier: tag)
    }
}

// MARK: - DEFAULT
extension ASN1 {
    /// Parses a value that is encoded with a DEFAULT.
    ///
    /// Such a value is optional, and if absent will be replaced with its default.
    ///
    /// - parameters:
    ///     - nodes: The ``ASN1/ASN1NodeCollection/Iterator`` to parse this element out of.
    ///     - identifier: The implicit tag. Defaults to the default tag for the element.
    ///     - defaultValue: The default value to use if there was no encoded value.
    ///     - builder: A closure that will be called with the node for the element, if the element is present.
    ///
    /// - returns: The parsed element, if it was present, or the default if it was not.
    @inlinable
    public static func decodeDefault<T: ASN1Parseable & Equatable>(_ nodes: inout ASN1.ASN1NodeCollection.Iterator, identifier: ASN1.ASN1Identifier, defaultValue: T, _ builder: (ASN1Node) throws -> T) throws -> T {
        // A weird trick here: we only want to consume the next node _if_ it has the right tag. To achieve that,
        // we work on a copy.
        var localNodesCopy = nodes
        guard let node = localNodesCopy.next() else {
            // Whoops, nothing here.
            return defaultValue
        }

        guard node.identifier == identifier else {
            // Node is a mismatch, with the wrong identifier. Our optional isn't present.
            return defaultValue
        }

        // We have the right optional, so let's consume it.
        nodes = localNodesCopy
        let parsed = try builder(node)

        // DER forbids encoding DEFAULT values at their default state.
        // We can lift this in BER.
        guard parsed != defaultValue else {
            throw ASN1Error.invalidASN1Object
        }

        return parsed
    }

    /// Parses a value that is encoded with a DEFAULT.
    ///
    /// Such a value is optional, and if absent will be replaced with its default. This function is
    /// a helper wrapper for ``decodeDefault(_:identifier:defaultValue:_:)`` that automatically invokes
    /// ``ASN1Parseable/init(asn1Encoded:)-507py`` on `T`.
    ///
    /// - parameters:
    ///     - nodes: The ``ASN1/ASN1NodeCollection/Iterator`` to parse this element out of.
    ///     - identifier: The implicit tag. Defaults to the default tag for the element.
    ///     - defaultValue: The default value to use if there was no encoded value.
    ///
    /// - returns: The parsed element, if it was present, or the default if it was not.
    @inlinable
    public static func decodeDefault<T: ASN1Parseable & Equatable>(_ nodes: inout ASN1.ASN1NodeCollection.Iterator, identifier: ASN1.ASN1Identifier, defaultValue: T) throws -> T {
        return try Self.decodeDefault(&nodes, identifier: identifier, defaultValue: defaultValue) { try T(asn1Encoded: $0) }
    }

    /// Parses a value that is encoded with a DEFAULT.
    ///
    /// Such a value is optional, and if absent will be replaced with its default. This function is
    /// a helper wrapper for ``decodeDefault(_:identifier:defaultValue:_:)`` that automatically invokes
    /// ``ASN1ImplicitlyTaggable/init(asn1Encoded:withIdentifier:)-iudo`` on `T` using ``ASN1ImplicitlyTaggable/defaultIdentifier``.
    ///
    /// - parameters:
    ///     - nodes: The ``ASN1/ASN1NodeCollection/Iterator`` to parse this element out of.
    ///     - defaultValue: The default value to use if there was no encoded value.
    ///
    /// - returns: The parsed element, if it was present, or the default if it was not.
    @inlinable
    public static func decodeDefault<T: ASN1ImplicitlyTaggable & Equatable>(_ nodes: inout ASN1.ASN1NodeCollection.Iterator, defaultValue: T) throws -> T {
        return try Self.decodeDefault(&nodes, identifier: T.defaultIdentifier, defaultValue: defaultValue)
    }

    /// Parses a value that is encoded with a DEFAULT and an explicit tag.
    ///
    /// Such a value is optional, and if absent will be replaced with its default.
    ///
    /// - parameters:
    ///     - nodes: The ``ASN1/ASN1NodeCollection/Iterator`` to parse this element out of.
    ///     - tagNumber: The number of the explicit tag.
    ///     - tagClass: The class of the explicit tag.
    ///     - defaultValue: The default value to use if there was no encoded value.
    ///     - builder: A closure that will be called with the node for the element, if the element is present.
    ///
    /// - returns: The parsed element, if it was present, or the default if it was not.
    @inlinable
    public static func decodeDefaultExplicitlyTagged<T: ASN1Parseable & Equatable>(_ nodes: inout ASN1.ASN1NodeCollection.Iterator, tagNumber: UInt, tagClass: ASN1.ASN1Identifier.TagClass, defaultValue: T, _ builder: (ASN1Node) throws -> T) throws -> T {
        if let result = try optionalExplicitlyTagged(&nodes, tagNumber: tagNumber, tagClass: tagClass, builder) {
            guard result != defaultValue else {
                // DER forbids encoding DEFAULT values at their default state.
                // We can lift this in BER.
                throw ASN1Error.invalidASN1Object
            }

            return result
        } else {
            return defaultValue
        }
    }

    /// Parses a value that is encoded with a DEFAULT and an explicit tag.
    ///
    /// Such a value is optional, and if absent will be replaced with its default. This function is
    /// a helper wrapper for ``decodeDefaultExplicitlyTagged(_:tagNumber:tagClass:defaultValue:_:)`` that automatically invokes
    /// ``ASN1Parseable/init(asn1Encoded:)-507py`` on `T`.
    ///
    /// - parameters:
    ///     - nodes: The ``ASN1/ASN1NodeCollection/Iterator`` to parse this element out of.
    ///     - tagNumber: The number of the explicit tag.
    ///     - tagClass: The class of the explicit tag.
    ///     - defaultValue: The default value to use if there was no encoded value.
    ///
    /// - returns: The parsed element, if it was present, or the default if it was not.
    @inlinable
    public static func decodeDefaultExplicitlyTagged<T: ASN1Parseable & Equatable>(_ nodes: inout ASN1.ASN1NodeCollection.Iterator, tagNumber: UInt, tagClass: ASN1.ASN1Identifier.TagClass, defaultValue: T) throws -> T {
        return try Self.decodeDefaultExplicitlyTagged(
            &nodes, tagNumber: tagNumber, tagClass: tagClass, defaultValue: defaultValue
        ) {
            try T(asn1Encoded: $0)
        }
    }
}

// MARK: - Ordinary, explicit tagging
extension ASN1 {
    /// Parses an explicitly tagged element.
    ///
    /// - parameters:
    ///     - nodes: The ``ASN1/ASN1NodeCollection/Iterator`` to parse this element out of.
    ///     - tagNumber: The number of the explicit tag.
    ///     - tagClass: The class of the explicit tag.
    ///     - builder: A closure that will be called with the node for the element.
    ///
    /// - returns: The result of `builder`.
    @inlinable
    public static func explicitlyTagged<T>(_ nodes: inout ASN1.ASN1NodeCollection.Iterator, tagNumber: UInt, tagClass: ASN1.ASN1Identifier.TagClass, _ builder: (ASN1Node) throws -> T) throws -> T {
        guard let node = nodes.next() else {
            // Node not present, throw.
            throw ASN1Error.invalidASN1Object
        }

        return try self.explicitlyTagged(node, tagNumber: tagNumber, tagClass: tagClass, builder)
    }

    /// Parses an explicitly tagged element.
    ///
    /// - parameters:
    ///     - node: The ``ASN1Node`` to parse this element out of.
    ///     - tagNumber: The number of the explicit tag.
    ///     - tagClass: The class of the explicit tag.
    ///     - builder: A closure that will be called with the node for the element.
    ///
    /// - returns: The result of `builder`.
    @inlinable
    public static func explicitlyTagged<T>(_ node: ASN1Node, tagNumber: UInt, tagClass: ASN1.ASN1Identifier.TagClass, _ builder: (ASN1Node) throws -> T) throws -> T {
        let expectedNodeID = ASN1.ASN1Identifier(explicitTagWithNumber: tagNumber, tagClass: tagClass)
        assert(expectedNodeID.constructed)
        guard node.identifier == expectedNodeID else {
            // Node is a mismatch, with the wrong tag.
            throw ASN1Error.invalidFieldIdentifier
        }

        // We expect a single child.
        guard case .constructed(let nodes) = node.content else {
            // This error is an internal parser error: the tag above is always constructed.
            preconditionFailure("Explicit tags are always constructed")
        }

        var nodeIterator = nodes.makeIterator()
        guard let child = nodeIterator.next(), nodeIterator.next() == nil else {
            throw ASN1Error.invalidASN1Object
        }

        return try builder(child)
    }
}


// MARK: - Parsing
extension ASN1 {
    /// A parsed representation of ASN.1.
    @usableFromInline
    struct ASN1ParseResult {
        @usableFromInline
        static let _maximumNodeDepth = 50

        @usableFromInline
        var nodes: ArraySlice<ASN1ParserNode>

        @inlinable
        init(_ nodes: ArraySlice<ASN1ParserNode>) {
            self.nodes = nodes
        }

        @inlinable
        static func parse(_ data: ArraySlice<UInt8>) throws -> ASN1ParseResult {
            var data = data
            var nodes = [ASN1ParserNode]()
            nodes.reserveCapacity(16)

            try _parseNode(from: &data, depth: 1, into: &nodes)
            guard data.count == 0 else {
                throw ASN1Error.invalidASN1Object
            }
            return ASN1ParseResult(nodes[...])
        }

        /// Parses a single ASN.1 node from the data and appends it to the buffer. This may recursively
        /// call itself when there are child nodes for constructed nodes.
        @inlinable
        static func _parseNode(from data: inout ArraySlice<UInt8>, depth: Int, into nodes: inout [ASN1ParserNode]) throws {
            guard depth <= ASN1.ASN1ParseResult._maximumNodeDepth else {
                // We defend ourselves against stack overflow by refusing to allocate more than 50 stack frames to
                // the parsing.
                throw ASN1Error.invalidASN1Object
            }

            let originalData = data

            guard let rawIdentifier = data.popFirst() else {
                throw ASN1Error.truncatedASN1Field
            }

            // Check whether the bottom 5 bits are set: if they are, this uses long-form encoding.
            let identifier: ASN1Identifier
            if (rawIdentifier & 0x1f) == 0x1f {
                let tagClass = ASN1Identifier.TagClass(topByteInWireFormat: rawIdentifier)
                let constructed = (rawIdentifier & 0x20) != 0

                // Now we need to read a UInt from the array.
                let tagNumber = try data.readUIntUsing8BitBytesASN1Discipline()

                // We need a check here: this number needs to be greater than or equal to 0x1f, or it should have been encoded as short form.
                guard tagNumber >= 0x1f else {
                    throw ASN1Error.invalidASN1Object
                }
                identifier = ASN1Identifier(tagWithNumber: tagNumber, tagClass: tagClass, constructed: constructed)
            } else {
                identifier = ASN1Identifier(shortIdentifier: rawIdentifier)
            }

            guard let wideLength = try data._readASN1Length() else {
                throw ASN1Error.truncatedASN1Field
            }

            // UInt is sometimes too large for us!
            guard let length = Int(exactly: wideLength) else {
                throw ASN1Error.invalidASN1Object
            }

            var subData = data.prefix(length)
            data = data.dropFirst(length)

            guard subData.count == length else {
                throw ASN1Error.truncatedASN1Field
            }

            let encodedBytes = originalData[..<subData.endIndex]

            if identifier.constructed {
                nodes.append(
                    ASN1ParserNode(
                        identifier: identifier,
                        depth: depth,
                        encodedBytes: encodedBytes,
                        dataBytes: nil
                    )
                )
                while subData.count > 0 {
                    try _parseNode(from: &subData, depth: depth + 1, into: &nodes)
                }
            } else {
                nodes.append(
                    ASN1ParserNode(
                        identifier: identifier,
                        depth: depth,
                        encodedBytes: encodedBytes,
                        dataBytes: subData
                    )
                )
            }
        }
    }
}

extension ASN1.ASN1ParseResult: Hashable { }

extension ASN1 {
    /// Parses an array of bytes as DER-encoded ASN.1 bytes.
    ///
    /// This function does not produce a complete decoded representation. Instead it produces a tree of ``ASN1Node`` objects,
    /// each representing a single ASN.1 object. The leaves of the tree are primitive ASN.1 objects, and the intermediate nodes are
    /// constructed.
    ///
    /// In general this function is not called by users directly. Prefer using ``ASN1Parseable/init(asn1Encoded:)-7otnm``, which encapsulates
    /// the use of this function and immediately returns a strongly typed, fully-parsed object.
    ///
    /// - parameters:
    ///     - data: The DER-encoded bytes to parse.
    /// - returns: The root node in the ASN.1 tree.
    @inlinable
    public static func parse(_ data: [UInt8]) throws -> ASN1Node {
        return try parse(data[...])
    }

    /// Parses an array of bytes as DER-encoded ASN.1 bytes.
    ///
    /// This function does not produce a complete decoded representation. Instead it produces a tree of ``ASN1Node`` objects,
    /// each representing a single ASN.1 object. The leaves of the tree are primitive ASN.1 objects, and the intermediate nodes are
    /// constructed.
    ///
    /// In general this function is not called by users directly. Prefer using ``ASN1Parseable/init(asn1Encoded:)-9ye4i``, which encapsulates
    /// the use of this function and immediately returns a strongly typed, fully-parsed object.
    ///
    /// - parameters:
    ///     - data: The DER-encoded bytes to parse.
    /// - returns: The root node in the ASN.1 tree.
    @inlinable
    public static func parse(_ data: ArraySlice<UInt8>) throws -> ASN1Node {
        var result = try ASN1ParseResult.parse(data)

        // There will always be at least one node if the above didn't throw, so we can safely just removeFirst here.
        let firstNode = result.nodes.removeFirst()

        let rootNode: ASN1Node
        if firstNode.identifier.constructed {
            // We need to feed it the next set of nodes.
            let nodeCollection = result.nodes.prefix { $0.depth > firstNode.depth }
            result.nodes = result.nodes.dropFirst(nodeCollection.count)
            rootNode = ASN1.ASN1Node(
                identifier: firstNode.identifier,
                content: .constructed(.init(nodes: nodeCollection, depth: firstNode.depth)),
                encodedBytes: firstNode.encodedBytes
            )
        } else {
            rootNode = ASN1.ASN1Node(
                identifier: firstNode.identifier,
                content: .primitive(firstNode.dataBytes!),
                encodedBytes: firstNode.encodedBytes
            )
        }

        precondition(result.nodes.count == 0, "ASN1ParseResult unexpectedly allowed multiple root nodes")

        return rootNode
    }
}

// MARK: - ASN1NodeCollection
extension ASN1 {
    /// Represents a collection of ASN.1 nodes contained in a constructed ASN.1 node.
    ///
    /// Constructed ASN.1 nodes are made up of multiple child nodes. This object represents the collection of those child nodes.
    /// It allows us to lazily construct the child nodes, potentially skipping over them when we don't care about them.
    ///
    /// This type cannot be constructed directly, and is instead provided by helper functions such as ``ASN1/sequence(of:identifier:rootNode:)``.
    public struct ASN1NodeCollection {
        @usableFromInline var _nodes: ArraySlice<ASN1ParserNode>

        @usableFromInline var _depth: Int

        @inlinable
        init(nodes: ArraySlice<ASN1ParserNode>, depth: Int) {
            self._nodes = nodes
            self._depth = depth

            precondition(self._nodes.allSatisfy({ $0.depth > depth }))
            if let firstDepth = self._nodes.first?.depth {
                precondition(firstDepth == depth + 1)
            }
        }
    }
}

extension ASN1.ASN1NodeCollection: Hashable { }

extension ASN1.ASN1NodeCollection: Sendable { }

extension ASN1.ASN1NodeCollection: Sequence {
    /// An iterator of ASN.1 nodes that are children of a specific constructed node.
    public struct Iterator: IteratorProtocol {
        @usableFromInline
        var _nodes: ArraySlice<ASN1.ASN1ParserNode>

        @usableFromInline
        var _depth: Int

        @inlinable
        init(nodes: ArraySlice<ASN1.ASN1ParserNode>, depth: Int) {
            self._nodes = nodes
            self._depth = depth
        }

        @inlinable
        public mutating func next() -> ASN1.ASN1Node? {
            guard let nextNode = self._nodes.popFirst() else {
                return nil
            }

            assert(nextNode.depth == self._depth + 1)
            if nextNode.identifier.constructed {
                // We need to feed it the next set of nodes.
                let nodeCollection = self._nodes.prefix { $0.depth > nextNode.depth }
                self._nodes = self._nodes.dropFirst(nodeCollection.count)
                return ASN1.ASN1Node(
                    identifier: nextNode.identifier,
                    content: .constructed(.init(nodes: nodeCollection, depth: nextNode.depth)),
                    encodedBytes: nextNode.encodedBytes
                )
            } else {
                // There must be data bytes here, even if they're empty.
                return ASN1.ASN1Node(
                    identifier: nextNode.identifier,
                    content: .primitive(nextNode.dataBytes!),
                    encodedBytes: nextNode.encodedBytes
                )
            }
        }
    }

    @inlinable
    public func makeIterator() -> Iterator {
        return Iterator(nodes: self._nodes, depth: self._depth)
    }
}

// MARK: - ASN1Node
extension ASN1 {
    /// An ``ASN1/ASN1Node`` is a single entry in the ASN.1 representation of a data structure.
    ///
    /// Conceptually, an ASN.1 data structure is rooted in a single node, which may itself contain zero or more
    /// other nodes. ASN.1 nodes are either "constructed", meaning they contain other nodes, or "primitive", meaning they
    /// store a base data type of some kind.
    ///
    /// In this way, ASN.1 objects tend to form a "tree", where each object is represented by a single top-level constructed
    /// node that contains other objects and primitives, eventually reaching the bottom which is made up of primitive objects.
    public struct ASN1Node: Hashable, Sendable {
        /// The tag for this ASN.1 node.
        public var identifier: ASN1Identifier

        /// The content of this ASN.1 node.
        public var content: Content

        /// The encoded bytes for this node.
        ///
        /// This is principally intended for diagnostic purposes.
        public var encodedBytes: ArraySlice<UInt8>

        @inlinable
        internal init(
            identifier: ASN1.ASN1Identifier,
            content: ASN1.ASN1Node.Content,
            encodedBytes: ArraySlice<UInt8>
        ) {
            self.identifier = identifier
            self.content = content
            self.encodedBytes = encodedBytes
        }
    }
}

// MARK: - ASN1Node.Content
extension ASN1.ASN1Node {
    /// The content of a single ``ASN1/ASN1Node``.
    public enum Content: Hashable, Sendable {
        /// This ``ASN1/ASN1Node`` is constructed, and has a number of child nodes.
        case constructed(ASN1.ASN1NodeCollection)

        /// This ``ASN1/ASN1Node`` is primitive, and is made up only of a collection of bytes.
        case primitive(ArraySlice<UInt8>)
    }
}

// MARK: - Serializing
extension ASN1 {
    /// An object that can serialize ASN.1 bytes.
    ///
    /// ``Serializer`` is a copy-on-write value type.
    public struct Serializer: Sendable {
        @usableFromInline
        var _serializedBytes: [UInt8]

        /// The bytes that have been serialized by this serializer.
        @inlinable
        public var serializedBytes: [UInt8] {
            self._serializedBytes
        }

        /// Construct a new serializer.
        @inlinable
        public init() {
            // We allocate a 1kB array because that should cover us most of the time.
            self._serializedBytes = []
            self._serializedBytes.reserveCapacity(1024)
        }

        /// Appends a single, non-constructed node to the content.
        ///
        /// This is a low-level operation that can be used to implement primitive ASN.1 types.
        ///
        /// - parameters:
        ///      - identifier: The tag for this ASN.1 node
        ///      - contentWriter: A callback that will be invoked that allows users to write their bytes into the output stream.
        @inlinable
        public mutating func appendPrimitiveNode(identifier: ASN1.ASN1Identifier, _ contentWriter: (inout [UInt8]) throws -> Void) rethrows {
            assert(identifier.primitive)
            try self._appendNode(identifier: identifier) { try contentWriter(&$0._serializedBytes) }
        }

        /// Appends a single constructed node to the content.
        ///
        /// This is an operation that can be used to implement constructed ASN.1 types. Most ASN.1 types are sequences and rely on using this function
        /// to append their SEQUENCE node.
        ///
        /// - parameters:
        ///      - identifier: The tag for this ASN.1 node
        ///      - contentWriter: A callback that will be invoked that allows users to write the objects contained within this constructed node.
        @inlinable
        public mutating func appendConstructedNode(identifier: ASN1.ASN1Identifier, _ contentWriter: (inout Serializer) throws -> Void) rethrows {
            assert(identifier.constructed)
            try self._appendNode(identifier: identifier, contentWriter)
        }

        /// Serializes a single node to the end of the byte stream.
        ///
        /// - parameters:
        ///     node: The node to be serialized.
        @inlinable
        public mutating func serialize<T: ASN1Serializable>(_ node: T) throws {
            try node.serialize(into: &self)
        }

        /// Serializes a single node to the end of the byte stream with an explicit ASN.1 tag.
        ///
        /// This is a wrapper for ``ASN1/Serializer/serialize(_:explicitlyTaggedWithIdentifier:)`` that builds the ASN.1 tag
        /// automatically.
        ///
        /// - parameters:
        ///     node: The node to be serialized.
        ///     tagNumber: The number of the explicit tag.
        ///     tagClass: The number of the explicit tag.
        @inlinable
        public mutating func serialize<T: ASN1Serializable>(_ node: T, explicitlyTaggedWithTagNumber tagNumber: UInt, tagClass: ASN1.ASN1Identifier.TagClass) throws {
            let identifier = ASN1Identifier(explicitTagWithNumber: tagNumber, tagClass: tagClass)
            return try self.serialize(node, explicitlyTaggedWithIdentifier: identifier)
        }

        /// Serializes a single node to the end of the byte stream with an explicit ASN.1 tag.
        ///
        /// - parameters:
        ///     node: The node to be serialized.
        ///     identifier: The explicit ASN.1 tag to apply.
        @inlinable
        public mutating func serialize<T: ASN1Serializable>(_ node: T, explicitlyTaggedWithIdentifier identifier: ASN1.ASN1Identifier) throws {
            try self.appendConstructedNode(identifier: identifier) { coder in
                try coder.serialize(node)
            }
        }

        /// Serializes a single optional node to the end of the byte stream with an implicit ASN.1 tag.
        ///
        /// If the node is `nil`, nothing is appended to the stream.
        ///
        /// The node is appended with its default tag.
        ///
        /// - parameters:
        ///     node: The node to be serialized.
        @inlinable
        public mutating func serializeOptionalImplicitlyTagged<T: ASN1Serializable>(_ node: T?) throws {
            if let node = node {
                try self.serialize(node)
            }
        }

        /// Serializes a single optional node to the end of the byte stream with an implicit ASN.1 tag.
        ///
        /// If the node is `nil`, nothing is appended to the stream.
        ///
        /// - parameters:
        ///     node: The node to be serialized.
        ///     identifier: The implicit ASN.1 tag to apply.
        @inlinable
        public mutating func serializeOptionalImplicitlyTagged<T: ASN1ImplicitlyTaggable>(_ node: T?, withIdentifier identifier: ASN1.ASN1Identifier) throws {
            if let node = node {
                try node.serialize(into: &self, withIdentifier: identifier)
            }
        }

        /// Serializes an explicit ASN.1 tag using a custom builder to store the elements of the explicitly tagged node.
        ///
        /// This is a helper version of ``ASN1/Serializer/serialize(_:explicitlyTaggedWithTagNumber:tagClass:)`` that allows users to avoid defining an object for the
        /// explicit node.
        ///
        /// - parameters:
        ///     tagNumber: The number of the explicit tag.
        ///     tagClass: The number of the explicit tag.
        ///     block: The block that will be invoked to encode the contents of the explicit tag.
        @inlinable
        public mutating func serialize(explicitlyTaggedWithTagNumber tagNumber: UInt, tagClass: ASN1.ASN1Identifier.TagClass, _ block: (inout Serializer) throws -> Void) rethrows {
            let identifier = ASN1Identifier(explicitTagWithNumber: tagNumber, tagClass: tagClass)
            try self.appendConstructedNode(identifier: identifier) { coder in
                try block(&coder)
            }
        }

        /// Serializes a SEQUENCE OF ASN.1 nodes.
        ///
        /// - parameters:
        ///     - elements: The members of the ASN.1 SEQUENCE OF.
        ///     - identifier: The identifier to use for the SEQUENCE OF node. Defaults to ``ASN1/ASN1Identifier/sequence``.
        @inlinable
        public mutating func serializeSequenceOf<Elements: Sequence>(_ elements: Elements, identifier: ASN1.ASN1Identifier = .sequence) throws where Elements.Element: ASN1Serializable {
            try self.appendConstructedNode(identifier: identifier) { coder in
                for element in elements {
                    try coder.serialize(element)
                }
            }
        }

        /// Serialize a parsed ASN.1 node directly.
        ///
        /// This is an extremely low-level helper function that can be used to re-serialize a parsed object when properly deserializing it was not
        /// practical.
        ///
        /// - parameters:
        ///     - node: The parsed node to serialize.
        @inlinable
        public mutating func serialize(_ node: ASN1.ASN1Node) {
            let identifier = node.identifier
            self._appendNode(identifier: identifier) { coder in
                switch node.content {
                case .constructed(let nodes):
                    for node in nodes {
                        coder.serialize(node)
                    }
                case .primitive(let baseData):
                    coder._serializedBytes.append(contentsOf: baseData)
                }
            }
        }

        // This is the base logical function that all other append methods are built on. This one has most of the logic, and doesn't
        // police what we expect to happen in the content writer.
        @inlinable
        mutating func _appendNode(identifier: ASN1.ASN1Identifier, _ contentWriter: (inout Serializer) throws -> Void) rethrows {
            // This is a tricky game to play. We want to write the identifier and the length, but we don't know what the
            // length is here. To get around that, we _assume_ the length will be one byte, and let the writer write their content.
            // If it turns out to have been longer, we recalculate how many bytes we need and shuffle them in the buffer,
            // before updating the length. Most of the time we'll be right: occasionally we'll be wrong and have to shuffle.
            self._serializedBytes.writeIdentifier(identifier)

            // Write a zero for the length.
            self._serializedBytes.append(0)

            // Save the indices and write.
            let originalEndIndex = self._serializedBytes.endIndex
            let lengthIndex = self._serializedBytes.index(before: originalEndIndex)

            try contentWriter(&self)

            let contentLength = self._serializedBytes.distance(from: originalEndIndex, to: self._serializedBytes.endIndex)
            let lengthBytesNeeded = contentLength._bytesNeededToEncode
            if lengthBytesNeeded == 1 {
                // We can just set this at the top, and we're done!
                assert(contentLength <= 0x7F)
                self._serializedBytes[lengthIndex] = UInt8(contentLength)
                return
            }

            // Whoops, we need more than one byte to represent the length. That's annoying!
            // To sort this out we want to "move" the memory to the right.
            self._serializedBytes._moveRange(offset: lengthBytesNeeded - 1, range: originalEndIndex..<self._serializedBytes.endIndex)

            // Now we can write the length bytes back. We first write the number of length bytes
            // we needed, setting the high bit. Then we write the bytes of the length.
            self._serializedBytes[lengthIndex] = 0x80 | UInt8(lengthBytesNeeded - 1)
            var writeIndex = lengthIndex

            for shift in (0..<(lengthBytesNeeded - 1)).reversed() {
                // Shift and mask the integer.
                self._serializedBytes.formIndex(after: &writeIndex)
                self._serializedBytes[writeIndex] = UInt8(truncatingIfNeeded: (contentLength >> (shift * 8)))
            }

            assert(writeIndex == self._serializedBytes.index(lengthIndex, offsetBy: lengthBytesNeeded - 1))
        }
    }
}

// MARK: - Helpers

/// Defines a type that can be parsed from a DER-encoded form.
///
/// Users implementing this type are expected to write the ASN.1 decoding code themselves. This approach is discussed in
/// depth in <doc:DecodingASN1>. When working with a type that may be implicitly tagged (which is most ASN.1 types),
/// users are recommended to implement ``ASN1ImplicitlyTaggable`` instead.
public protocol ASN1Parseable {
    /// Initialize this object from a serialized DER representation.
    ///
    /// This function is invoked by the parser with the root node for the ASN.1 object. Implementers are
    /// expected to initialize themselves if possible, or to throw if they cannot.
    ///
    /// - parameters:
    ///     - asn1Encoded: The ASN.1 node representing this object.
    init(asn1Encoded: ASN1.ASN1Node) throws
}

extension ASN1Parseable {
    /// Initialize this object as one element of a constructed ASN.1 object.
    ///
    /// This is a helper function for parsing constructed ASN.1 objects. It delegates all its functionality
    /// to ``ASN1Parseable/init(asn1Encoded:)-507py``.
    ///
    /// - parameters:
    ///     - asn1Encoded: The sequence of nodes that make up this object's parent. The first node in this collection
    ///         will be used to construct this object.
    @inlinable
    public init(asn1Encoded sequenceNodeIterator: inout ASN1.ASN1NodeCollection.Iterator) throws {
        guard let node = sequenceNodeIterator.next() else {
            throw ASN1Error.invalidASN1Object
        }

        self = try .init(asn1Encoded: node)
    }

    /// Initialize this object from a serialized DER representation.
    ///
    /// - parameters:
    ///     - asn1Encoded: The DER-encoded bytes representing this object.
    @inlinable
    public init(asn1Encoded: [UInt8]) throws {
        self = try .init(asn1Encoded: ASN1.parse(asn1Encoded))
    }

    /// Initialize this object from a serialized DER representation.
    ///
    /// - parameters:
    ///     - asn1Encoded: The DER-encoded bytes representing this object.
    @inlinable
    public init(asn1Encoded: ArraySlice<UInt8>) throws {
        self = try .init(asn1Encoded: ASN1.parse(asn1Encoded))
    }
}

/// Defines a type that can be serialized in DER-encoded form.
///
/// Users implementing this type are expected to write the ASN.1 serialization code themselves. This approach is discussed in
/// depth in <doc:DecodingASN1>. When working with a type that may be implicitly tagged (which is most ASN.1 types),
/// users are recommended to implement ``ASN1ImplicitlyTaggable`` instead.
public protocol ASN1Serializable {
    /// Serialize this object into DER-encoded ASN.1 form.
    ///
    /// - parameters:
    ///     - coder: A serializer to be used to encode the object.
    func serialize(into coder: inout ASN1.Serializer) throws
}

/// An ASN.1 node that can tolerate having an implicit tag.
///
/// Implicit tags prevent the decoder from being able to work out what the actual type of the object
/// is, as they replace the tags. This means some objects cannot be implicitly tagged. In particular,
/// CHOICE elements without explicit tags cannot be implicitly tagged.
///
/// Objects that _can_ be implicitly tagged should prefer to implement this protocol than
/// ``ASN1Serializable`` and ``ASN1Parseable``.
public protocol ASN1ImplicitlyTaggable: ASN1Parseable, ASN1Serializable {
    /// The tag that the first node will use "by default" if the grammar omits
    /// any more specific tag definition.
    static var defaultIdentifier: ASN1.ASN1Identifier { get }

    /// Initialize this object from a serialized DER representation.
    ///
    /// This function is invoked by the parser with the root node for the ASN.1 object. Implementers are
    /// expected to initialize themselves if possible, or to throw if they cannot. The object is expected
    /// to use the identifier `identifier`.
    ///
    /// - parameters:
    ///     - asn1Encoded: The ASN.1 node representing this object.
    ///     - identifier: The ASN.1 identifier that `asn1Encoded` is expected to have.
    init(asn1Encoded: ASN1.ASN1Node, withIdentifier identifier: ASN1.ASN1Identifier) throws

    /// Serialize this object into DER-encoded ASN.1 form.
    ///
    /// - parameters:
    ///     - coder: A serializer to be used to encode the object.
    ///     - identifier: The ASN.1 identifier that this object should use to represent itself.
    func serialize(into coder: inout ASN1.Serializer, withIdentifier identifier: ASN1.ASN1Identifier) throws
}

extension ASN1ImplicitlyTaggable {
    /// Initialize this object as one element of a constructed ASN.1 object.
    ///
    /// This is a helper function for parsing constructed ASN.1 objects. It delegates all its functionality
    /// to ``ASN1ImplicitlyTaggable/init(asn1Encoded:withIdentifier:)-iudo``.
    ///
    /// - parameters:
    ///     - asn1Encoded: The sequence of nodes that make up this object's parent. The first node in this collection
    ///         will be used to construct this object.
    ///     - identifier: The ASN.1 identifier that `asn1Encoded` is expected to have.
    @inlinable
    public init(asn1Encoded sequenceNodeIterator: inout ASN1.ASN1NodeCollection.Iterator,
                withIdentifier identifier: ASN1.ASN1Identifier = Self.defaultIdentifier) throws {
        guard let node = sequenceNodeIterator.next() else {
            throw ASN1Error.invalidASN1Object
        }

        self = try .init(asn1Encoded: node, withIdentifier: identifier)
    }

    /// Initialize this object from a serialized DER representation.
    ///
    /// - parameters:
    ///     - asn1Encoded: The DER-encoded bytes representing this object.
    ///     - identifier: The ASN.1 identifier that `asn1Encoded` is expected to have.
    @inlinable
    public init(asn1Encoded: [UInt8], withIdentifier identifier: ASN1.ASN1Identifier = Self.defaultIdentifier) throws {
        self = try .init(asn1Encoded: ASN1.parse(asn1Encoded), withIdentifier: identifier)
    }

    /// Initialize this object from a serialized DER representation.
    ///
    /// - parameters:
    ///     - asn1Encoded: The DER-encoded bytes representing this object.
    ///     - identifier: The ASN.1 identifier that `asn1Encoded` is expected to have.
    @inlinable
    public init(asn1Encoded: ArraySlice<UInt8>, withIdentifier identifier: ASN1.ASN1Identifier = Self.defaultIdentifier) throws {
        self = try .init(asn1Encoded: ASN1.parse(asn1Encoded), withIdentifier: identifier)
    }

    @inlinable
    public init(asn1Encoded: ASN1.ASN1Node) throws {
        try self.init(asn1Encoded: asn1Encoded, withIdentifier: Self.defaultIdentifier)
    }

    @inlinable
    public func serialize(into coder: inout ASN1.Serializer) throws {
        try self.serialize(into: &coder, withIdentifier: Self.defaultIdentifier)
    }
}

extension ArraySlice where Element == UInt8 {
    @inlinable
    mutating func _readASN1Length() throws -> UInt? {
        guard let firstByte = self.popFirst() else {
            return nil
        }

        switch firstByte {
        case 0x80:
            // Indefinite form. Unsupported.
            throw ASN1Error.unsupportedFieldLength
        case let val where val & 0x80 == 0x80:
            // Top bit is set, this is the long form. The remaining 7 bits of this octet
            // determine how long the length field is.
            let fieldLength = Int(val & 0x7F)
            guard self.count >= fieldLength else {
                return nil
            }

            // We need to read the length bytes
            let lengthBytes = self.prefix(fieldLength)
            self = self.dropFirst(fieldLength)
            let length = try UInt(bigEndianBytes: lengthBytes)

            // DER requires that we enforce that the length field was encoded in the minimum number of octets necessary.
            let requiredBits = UInt.bitWidth - length.leadingZeroBitCount
            switch requiredBits {
            case 0...7:
                // For 0 to 7 bits, the long form is unnacceptable and we require the short.
                throw ASN1Error.unsupportedFieldLength
            case 8...:
                // For 8 or more bits, fieldLength should be the minimum required.
                let requiredBytes = (requiredBits + 7) / 8
                if fieldLength > requiredBytes {
                    throw ASN1Error.unsupportedFieldLength
                }
            default:
                // This is not reachable, but we'll error anyway.
                throw ASN1Error.unsupportedFieldLength
            }

            return length
        case let val:
            // Short form, the length is only one 7-bit integer.
            return UInt(val)
        }
    }
}

extension FixedWidthInteger {
    @inlinable
    internal init<Bytes: Collection>(bigEndianBytes bytes: Bytes) throws where Bytes.Element == UInt8 {
        guard bytes.count <= (Self.bitWidth / 8) else {
            throw ASN1Error.invalidASN1Object
        }

        self = 0
        let shiftSizes = stride(from: 0, to: bytes.count * 8, by: 8).reversed()

        var index = bytes.startIndex
        for shift in shiftSizes {
            self |= Self(truncatingIfNeeded: bytes[index]) << shift
            bytes.formIndex(after: &index)
        }
    }
}

extension Array where Element == UInt8 {
    @inlinable
    mutating func _moveRange(offset: Int, range: Range<Index>) {
        // We only bothered to implement this for positive offsets for now, the algorithm
        // generalises.
        precondition(offset > 0)

        let distanceFromEndOfRangeToEndOfSelf = self.distance(from: range.endIndex, to: self.endIndex)
        if distanceFromEndOfRangeToEndOfSelf < offset {
            // We begin by writing some zeroes out to the size we need.
            for _ in 0..<(offset - distanceFromEndOfRangeToEndOfSelf) {
                self.append(0)
            }
        }

        // Now we walk the range backwards, moving the elements.
        for index in range.reversed() {
            self[index + offset] = self[index]
        }
    }
}

extension Int {
    @inlinable
    var _bytesNeededToEncode: Int {
        // ASN.1 lengths are in two forms. If we can store the length in 7 bits, we should:
        // that requires only one byte. Otherwise, we need multiple bytes: work out how many,
        // plus one for the length of the length bytes.
        if self <= 0x7F {
            return 1
        } else {
            // We need to work out how many bytes we need. There are many fancy bit-twiddling
            // ways of doing this, but honestly we don't do this enough to need them, so we'll
            // do it the easy way. This math is done on UInt because it makes the shift semantics clean.
            // We save a branch here because we can never overflow this addition.
            return UInt(self).neededBytes &+ 1
        }
    }
}

extension FixedWidthInteger {
    // Bytes needed to store a given integer.
    @inlinable
    internal var neededBytes: Int {
        let neededBits = self.bitWidth - self.leadingZeroBitCount
        return (neededBits + 7) / 8
    }
}