// Sources/SwiftProtobuf/Google_Protobuf_Any+Extensions.swift - Well-known Any type
//
// Copyright (c) 2014 - 2017 Apple Inc. and the project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See LICENSE.txt for license information:
// https://github.com/apple/swift-protobuf/blob/master/LICENSE.txt
//
// -----------------------------------------------------------------------------
///
/// Extends the Google_Protobuf_Any and Message structs with various
/// custom behaviors.
///
// -----------------------------------------------------------------------------

import Foundation


public extension Message {
  /// Initialize this message from the provided `google.protobuf.Any`
  /// well-known type.
  ///
  /// This corresponds to the `unpack` method in the Google C++ API.
  ///
  /// If the Any object was decoded from Protobuf Binary or JSON
  /// format, then the enclosed field data was stored and is not
  /// fully decoded until you unpack the Any object into a message.
  /// As such, this method will typically need to perform a full
  /// deserialization of the enclosed data and can fail for any
  /// reason that deserialization can fail.
  ///
  /// See `Google_Protobuf_Any.unpackTo()` for more discussion.
  ///
  /// - Parameter unpackingAny: the message to decode.
  /// - Throws: an instance of `AnyUnpackError`, `JSONDecodingError`, or
  ///   `BinaryDecodingError` on failure.
  public init(unpackingAny: Google_Protobuf_Any) throws {
    self.init()
    try unpackingAny.unpackTo(target: &self)
  }
}


public extension Google_Protobuf_Any {

  /// Initialize an Any object from the provided message.
  ///
  /// This corresponds to the `pack` operation in the C++ API.
  ///
  /// Unlike the C++ implementation, the message is not immediately
  /// serialized; it is merely stored until the Any object itself
  /// needs to be serialized.  This design avoids unnecessary
  /// decoding/recoding when writing JSON format.
  ///
  public init(message: Message, typePrefix: String = defaultTypePrefix) {
    self.init()
    _message = message
    typeURL = buildTypeURL(forMessage:message, typePrefix: typePrefix)
  }


  /// Decode an Any object from Protobuf Text Format.
  public init(textFormatString: String, extensions: ExtensionSet? = nil) throws {
    self.init()
    var textDecoder = try TextFormatDecoder(messageType: Google_Protobuf_Any.self,
                                            text: textFormatString,
                                            extensions: extensions)
    try decodeTextFormat(decoder: &textDecoder)
    if !textDecoder.complete {
      throw TextFormatDecodingError.trailingGarbage
    }
  }

  ///
  /// Update the provided object from the data in the Any container.
  /// This is essentially just a deferred deserialization; the Any
  /// may hold protobuf bytes or JSON fields depending on how the Any
  /// was itself deserialized.
  ///
  public func unpackTo<M: Message>(target: inout M) throws {
    if typeURL == nil {
      throw AnyUnpackError.emptyAnyField
    }
    let encodedType = typeName(fromURL: typeURL!)
    if encodedType.isEmpty {
      throw AnyUnpackError.malformedTypeURL
    }
    let messageType = typeName(fromMessage: target)
    if encodedType != messageType {
      throw AnyUnpackError.typeMismatch
    }
    var protobuf: Data?
    if let message = _message as? M {
      target = message
      return
    }

    if let message = _message {
      protobuf = try message.serializedData()
    } else if let value = _value {
      protobuf = value
    }
    if let protobuf = protobuf {
      // Decode protobuf from the stored bytes
      if protobuf.count > 0 {
        try protobuf.withUnsafeBytes { (p: UnsafePointer<UInt8>) in
          try target._protobuf_mergeSerializedBytes(from: p, count: protobuf.count, extensions: nil)
        }
      }
      return
    } else if let contentJSON = _contentJSON {
      let targetType = typeName(fromMessage: target)
      if Google_Protobuf_Any.isWellKnownType(messageName: targetType) {
        try contentJSON.withUnsafeBytes { (bytes:UnsafePointer<UInt8>) in
          var scanner = JSONScanner(utf8Pointer: bytes,
                                    count: contentJSON.count)
          let key = try scanner.nextQuotedString()
          if key != "value" {
            // The only thing within a WKT should be "value".
            throw AnyUnpackError.malformedWellKnownTypeJSON
          }
          try scanner.skipRequiredColon()  // Can't fail
          let value = try scanner.skip()
          if !scanner.complete {
            // If that wasn't the end, then there was another key,
            // and WKTs should only have the one.
            throw AnyUnpackError.malformedWellKnownTypeJSON
          }
          // Note: This api is unpackTo(target:) so it really should be
          // a merge and not a replace (the non WKT case next is a merge).
          // The only WKTs where there would seem to be a difference are:
          //   Struct - It is a map, so it would merge into any existing
          //     enties.
          //   ValueList - Repeated, so values should append to the
          //       existing ones instead of instead of replace.
          //   FieldMask - Repeated, so values should append to the
          //       existing ones instead of instead of replace.
          //   Value - Interesting case, it is a oneof, so currently
          //       that would error if it was already set, so maybe
          //       replace is ok.
          target = try M(jsonString: value)
        }
      } else {
        let asciiOpenCurlyBracket = UInt8(ascii: "{")
        let asciiCloseCurlyBracket = UInt8(ascii: "}")
        var contentJSONAsObject = Data(bytes: [asciiOpenCurlyBracket])
        contentJSONAsObject.append(contentJSON)
        contentJSONAsObject.append(asciiCloseCurlyBracket)

        try contentJSONAsObject.withUnsafeBytes { (bytes:UnsafePointer<UInt8>) in
          var decoder = JSONDecoder(utf8Pointer: bytes,
                                    count: contentJSONAsObject.count)
          try decoder.decodeFullObject(message: &target)
          if !decoder.scanner.complete {
            throw JSONDecodingError.trailingGarbage
          }
        }
      }
      return
    }
    throw AnyUnpackError.malformedAnyField
  }

}


extension Google_Protobuf_Any {

  // Custom text format decoding support for Any objects.
  // (Note: This is not a part of any protocol; it's invoked
  // directly from TextFormatDecoder whenever it sees an attempt
  // to decode an Any object)
  internal mutating func decodeTextFormat(decoder: inout TextFormatDecoder) throws {
    // First, check if this uses the "verbose" Any encoding.
    // If it does, and we have the type available, we can
    // eagerly decode the contained Message object.
    if let url = try decoder.scanner.nextOptionalAnyURL() {
      // Decoding the verbose form requires knowing the type:
      typeURL = url
      let messageTypeName = typeName(fromURL: url)
      let terminator = try decoder.scanner.skipObjectStart()
      // Is it a well-known type? Or a user-registered type?
      if messageTypeName == "google.protobuf.Any" {
        var subDecoder = try TextFormatDecoder(messageType: Google_Protobuf_Any.self, scanner: decoder.scanner, terminator: terminator)
        var any = Google_Protobuf_Any()
        try any.decodeTextFormat(decoder: &subDecoder)
        decoder.scanner = subDecoder.scanner
        if let _ = try decoder.nextFieldNumber() {
          // Verbose any can never have additional keys
          throw TextFormatDecodingError.malformedText
        }
        _message = any
        return
      } else if let messageType = Google_Protobuf_Any.lookupMessageType(forMessageName: messageTypeName) {
        var subDecoder = try TextFormatDecoder(messageType: messageType, scanner: decoder.scanner, terminator: terminator)
        _message = messageType.init()
        try _message!.decodeMessage(decoder: &subDecoder)
        decoder.scanner = subDecoder.scanner
        if let _ = try decoder.nextFieldNumber() {
          // Verbose any can never have additional keys
          throw TextFormatDecodingError.malformedText
        }
        return
      }
      // TODO: If we don't know the type, we should consider deferring the
      // decode as we do for JSON and Protobuf binary.
      throw TextFormatDecodingError.malformedText
    }

    // This is not using the specialized encoding, so we can use the
    // standard path to decode the binary value.
    try decodeMessage(decoder: &decoder)
  }

}
