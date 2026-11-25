import Foundation

/// A configuration profile that turns Apple Intelligence off on an iPhone or
/// iPad. It uses the same restriction keys as the Mac profile where Apple
/// documents them for iOS and iPadOS. Forced preferences and model deletion
/// stay on the Mac: iOS and iPadOS do not let a profile delete the models.
enum Mobile {
  enum Device: String {
    case iPhone
    case iPad

    /// `ios` is the iPhone profile. `ipados` is the iPad profile.
    init?(argument: String) {
      switch argument.lowercased() {
      case "iphone", "ios": self = .iPhone
      case "ipad", "ipados": self = .iPad
      default: return nil
      }
    }

    var profileIdentifier: String { "io.github.omlahore.removemacai.\(rawValue.lowercased())" }
    var systemName: String { self == .iPhone ? "iOS" : "iPadOS" }
  }

  /// One Apple Intelligence feature a profile can switch off.
  /// `supervised` is Apple's rule: the device has to be supervised or the
  /// switch is ignored. Siri and the ChatGPT extension do not need that.
  struct Feature {
    let id: String
    let title: String
    let restrictions: [String]
    let supervised: Bool
  }

  static let features: [Feature] = [
    Feature(
      id: "siri", title: "Siri and Siri AI",
      restrictions: ["allowAssistant", "allowSiriAI"], supervised: false),
    Feature(
      id: "chatgpt", title: "ChatGPT and other AI extensions",
      restrictions: [
        "allowExternalIntelligenceIntegrations", "allowExternalIntelligenceIntegrationsSignIn",
      ], supervised: false),
    Feature(
      id: "writing-tools", title: "Writing Tools",
      restrictions: ["allowWritingTools"], supervised: true),
    Feature(
      id: "genmoji", title: "Genmoji",
      restrictions: ["allowGenmoji"], supervised: true),
    Feature(
      id: "image-playground", title: "Image Playground",
      restrictions: ["allowImagePlayground"], supervised: true),
    Feature(
      id: "image-wand", title: "Image Wand",
      restrictions: ["allowImageWand"], supervised: true),
    Feature(
      id: "mail", title: "Mail summaries and smart replies",
      restrictions: ["allowMailSummary", "allowMailSmartReplies"], supervised: true),
    Feature(
      id: "safari-summaries", title: "Safari summaries",
      restrictions: ["allowSafariSummary"], supervised: true),
    Feature(
      id: "notes-summaries", title: "Notes transcription summaries",
      restrictions: ["allowNotesTranscriptionSummary"], supervised: true),
    Feature(
      id: "visual-intelligence", title: "Visual Intelligence summaries",
      restrictions: ["allowVisualIntelligenceSummary"], supervised: true),
  ]

  static func feature(_ id: String) -> Feature? { features.first { $0.id == id } }

  /// iPhone and iPad use the same restriction keys. Apple's schema lists them under iOS.
  static func features(for _: Device) -> [Feature] { features }

  /// The profile for `device`, with every feature off except `kept`.
  static func data(keeping kept: Set<String>, device: Device) throws -> Data {
    var restrictions = payload(device: device)
    for feature in features(for: device) where !kept.contains(feature.id) {
      for key in feature.restrictions { restrictions[key] = false }
    }
    let supervised = features(for: device).filter(\.supervised).map(\.title).joined(separator: ", ")
    let mailNote = kept.contains("mail")
      ? ""
      : " Mail summaries turn off the ones you start yourself. Mail can still write them on its own."
    let description = """
    Turns off Apple Intelligence on this \(device.rawValue). Remove the profile and the switches come back. \
    \(device.systemName) does not let a profile delete the model files. \
    Siri applies without supervision. Siri AI and ChatGPT extensions apply without supervision, and Shared iPad ignores them. \(supervised) apply on a supervised device. Shared iPad ignores those too.\(mailNote)
    """
    let profile: [String: Any] = [
      "PayloadType": "Configuration",
      "PayloadVersion": 1,
      "PayloadIdentifier": device.profileIdentifier,
      "PayloadUUID": Profile.uuid(device.profileIdentifier),
      "PayloadDisplayName": "RemoveMacAI",
      "PayloadDescription": description,
      "PayloadOrganization": "RemoveMacAI",
      "PayloadRemovalDisallowed": false,
      "PayloadContent": [restrictions],
    ]
    return try PropertyListSerialization.data(fromPropertyList: profile, format: .xml, options: 0)
  }

  private static func payload(device: Device) -> [String: Any] {
    let id = device.profileIdentifier + ".restrictions"
    return [
      "PayloadType": "com.apple.applicationaccess",
      "PayloadVersion": 1,
      "PayloadIdentifier": id,
      "PayloadUUID": Profile.uuid(id),
      "PayloadDisplayName": "Apple Intelligence",
    ]
  }
}
