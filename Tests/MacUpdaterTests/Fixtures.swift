import Foundation
import XCTest

func fixtureData(named name: String, extension fileExtension: String) throws -> Data {
    let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: fileExtension))
    return try Data(contentsOf: url)
}

func fixtureString(named name: String, extension fileExtension: String) throws -> String {
    String(decoding: try fixtureData(named: name, extension: fileExtension), as: UTF8.self)
}
