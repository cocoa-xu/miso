import Foundation

public enum MisoError: Error, LocalizedError, Equatable {
  case invalid(String)
  case unsupported(String)
  case system(String, Int32)

  public var errorDescription: String? {
    switch self {
    case .invalid(let message): message
    case .unsupported(let message): "Unsupported: \(message)"
    case .system(let operation, let code): "\(operation): \(String(cString: strerror(code)))"
    }
  }
}
