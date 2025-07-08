import Foundation

enum AppError: Error, LocalizedError {
    case missingDocumentsDirectory
    case invalidData
    case castFailed
    case unknown

    var errorDescription: String? {
        switch self {
        case .missingDocumentsDirectory:
            return "Unable to access the documents directory."
        case .invalidData:
            return "Invalid or missing data."
        case .castFailed:
            return "Type casting failed."
        case .unknown:
            return "An unknown error occurred."
        }
    }
}