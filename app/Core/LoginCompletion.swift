import Foundation

public enum LoginCompletion {
    @discardableResult
    public static func persistThenClose(
        persist: () throws -> Void,
        close: () -> Void
    ) -> Result<Void, Error> {
        do {
            try persist()
            close()
            return .success(())
        } catch {
            return .failure(error)
        }
    }
}