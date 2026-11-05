import Vapor

extension Application.CompositionRoot {

    func firestorePrefix(_ prefix: String) -> String {
        guard let base = Environment.get("FIRESTORE_PATH_PREFIX"), base.isEmpty == false else {
            return prefix
        }
        return "\(base)/\(prefix)"
    }

}
