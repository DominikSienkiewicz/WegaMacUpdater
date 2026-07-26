import Foundation

/// The Squirrel.Mac update-feed body, as a single `Decodable` shared by every checker that
/// reads it. A 200 response carries `{"name":"<latest>", …}`; both Postman's and Discord's
/// self-update feeds speak this format, so they decode it through this one model instead of
/// each declaring its own.
struct SquirrelResponse: Decodable {
    let name: String
}
