//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftCrypto open source project
//
// Copyright (c) 2021 Apple Inc. and the SwiftCrypto project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of SwiftCrypto project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

extension ASN1 {
    /// GeneralizedTime represents a date and time.
    ///
    /// In DER format, this is always in the form of `YYYYMMDDHHMMSSZ`. The type in
    /// general is capable of expressing fractional seconds. The time is always in the
    /// UTC time zone.
    public struct GeneralizedTime: ASN1ImplicitlyTaggable, Hashable, Sendable {
        @inlinable
        public static var defaultIdentifier: ASN1.ASN1Identifier {
            .generalizedTime
        }

        /// The numerical year.
        @inlinable
        public var year: Int {
            get {
                return self._year
            }
            set {
                self._year = newValue
                try! self._validate()
            }
        }

        /// The numerical month.
        @inlinable
        public var month: Int {
            get {
                return self._month
            }
            set {
                self._month = newValue
                try! self._validate()
            }
        }

        /// The numerical day.
        @inlinable
        public var day: Int {
            get {
                return self._day
            }
            set {
                self._day = newValue
                try! self._validate()
            }
        }

        /// The numerical hours.
        @inlinable
        public var hours: Int {
            get {
                return self._hours
            }
            set {
                self._hours = newValue
                try! self._validate()
            }
        }

        /// The numerical minutes.
        @inlinable
        public var minutes: Int {
            get {
                return self._minutes
            }
            set {
                self._minutes = newValue
                try! self._validate()
            }
        }

        /// The numerical seconds.
        @inlinable
        public var seconds: Int {
            get {
                return self._seconds
            }
            set {
                self._seconds = newValue
                try! self._validate()
            }
        }

        /// The fractional seconds.
        @inlinable
        public var fractionalSeconds: Double {
            get {
                return self._fractionalSeconds
            }
            set {
                self._fractionalSeconds = newValue
                try! self._validate()
            }
        }

        @usableFromInline var _year: Int
        @usableFromInline var _month: Int
        @usableFromInline var _day: Int
        @usableFromInline var _hours: Int
        @usableFromInline var _minutes: Int
        @usableFromInline var _seconds: Int
        @usableFromInline var _fractionalSeconds: Double

        /// Construct a new ``ASN1/GeneralizedTime`` from individual components.
        ///
        /// - parameters:
        ///     - year: The numerical year
        ///     - month: The numerical month
        ///     - day: The numerical day
        ///     - hours: The numerical hours
        ///     - minutes: The numerical minutes
        ///     - seconds: The numerical seconds
        ///     - fractionalSeconds: The numerical fractional seconds.
        @inlinable
        public init(year: Int, month: Int, day: Int, hours: Int, minutes: Int, seconds: Int, fractionalSeconds: Double) throws {
            self._year = year
            self._month = month
            self._day = day
            self._hours = hours
            self._minutes = minutes
            self._seconds = seconds
            self._fractionalSeconds = fractionalSeconds

            try self._validate()
        }

        @inlinable
        public init(asn1Encoded node: ASN1.ASN1Node, withIdentifier identifier: ASN1.ASN1Identifier) throws {
            guard node.identifier == identifier else {
                throw ASN1Error.unexpectedFieldType
            }

            guard case .primitive(let content) = node.content else {
                preconditionFailure("ASN.1 parser generated primitive node with constructed content")
            }

            self = try TimeUtilities.generalizedTimeFromBytes(content)
        }

        @inlinable
        public func serialize(into coder: inout ASN1.Serializer, withIdentifier identifier: ASN1.ASN1Identifier) throws {
            coder.appendPrimitiveNode(identifier: identifier) { bytes in
                bytes.append(self)
            }
        }

        @inlinable
        func _validate() throws {
            // Validate that the structure is well-formed.
            guard self._year >= 0 && self._year <= 9999 else {
                throw ASN1Error.invalidASN1Object
            }

            // This also validates the month.
            guard let daysInMonth = TimeUtilities.daysInMonth(self._month, ofYear: self._year) else {
                throw ASN1Error.invalidASN1Object
            }

            guard self._day >= 1 && self._day <= daysInMonth else {
                throw ASN1Error.invalidASN1Object
            }

            guard self._hours >= 0 && self._hours < 24 else {
                throw ASN1Error.invalidASN1Object
            }

            guard self._minutes >= 0 && self._minutes < 60 else {
                throw ASN1Error.invalidASN1Object
            }

            // We allow leap seconds here, but don't validate it.
            // This exposes us to potential confusion if we naively implement
            // comparison here. We should consider whether this needs to be transformable
            // to `Date` or similar.
            guard self._seconds >= 0 && self._seconds <= 61 else {
                throw ASN1Error.invalidASN1Object
            }

            // Fractional seconds may not be negative and may not be 1 or more.
            guard self._fractionalSeconds >= 0 && self._fractionalSeconds < 1 else {
                throw ASN1Error.invalidASN1Object
            }
        }
    }
}