struct FriendlyNamer: Sendable {
    static let adjectives: Set<String> = [
        "Mystic","Swift", "Silent", "Golden", "Neon", "Brave", "Fierce", "Radiant", "Luminous", "Vivid", "Celestial", "Enchanted", "Glorious", "Majestic", "Noble", "Radiant", "Sleek", "Vibrant", "Whispering", "Zephyr"
    ]
    static let nouns: Set<String> = [
        "Eagle", "River", "Shadow", "Cloud", "Bolt", "Phoenix", "Wolf", "Dragon", "Falcon", "Tiger", "Lion", "Panther", "Leopard", "Cheetah", "Jaguar", "Puma", "Cougar", "Lynx", "Ocelot", "Caracal"
    ]

    static func generate() -> String {
        let adjective = adjectives.randomElement() ?? "Swift"
        let noun = nouns.randomElement() ?? "Eagle"
        return "\(adjective)-\(noun)"
    }
}
