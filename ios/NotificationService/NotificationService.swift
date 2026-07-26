import Foundation
import SQLite3
import UserNotifications
import flutter_vodozemac

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class NotificationService: UNNotificationServiceExtension {
  private static let appGroup = "group.com.patricklamphier.patrickMessenger"

  private var contentHandler: ((UNNotificationContent) -> Void)?
  private var bestAttemptContent: UNMutableNotificationContent?

  override func didReceive(
    _ request: UNNotificationRequest,
    withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
  ) {
    self.contentHandler = contentHandler
    guard let content = request.content.mutableCopy() as? UNMutableNotificationContent else {
      contentHandler(request.content)
      return
    }
    bestAttemptContent = content
    content.body = "New encrypted message"

    guard
      let defaults = UserDefaults(suiteName: Self.appGroup),
      defaults.bool(forKey: "showPreviews"),
      let homeserver = defaults.string(forKey: "homeserver"),
      let accessToken = defaults.string(forKey: "accessToken"),
      let userId = defaults.string(forKey: "userId"),
      let roomId = request.content.userInfo["room_id"] as? String,
      let eventId = request.content.userInfo["event_id"] as? String,
      let eventURL = matrixEventURL(
        homeserver: homeserver,
        roomId: roomId,
        eventId: eventId
      )
    else {
      contentHandler(content)
      return
    }

    var eventRequest = URLRequest(url: eventURL)
    eventRequest.timeoutInterval = 12
    eventRequest.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
    URLSession.shared.dataTask(with: eventRequest) { [weak self] data, response, _ in
      guard
        let self,
        let httpResponse = response as? HTTPURLResponse,
        httpResponse.statusCode == 200,
        let data,
        let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let encryptedContent = event["content"] as? [String: Any],
        let sessionId = encryptedContent["session_id"] as? String,
        let ciphertext = encryptedContent["ciphertext"] as? String,
        let body = self.decrypt(
          sessionId: sessionId,
          ciphertext: ciphertext,
          userId: userId
        )
      else {
        contentHandler(content)
        return
      }

      content.title = self.readableSender(event["sender"] as? String)
      content.body = body
      contentHandler(content)
    }.resume()
  }

  override func serviceExtensionTimeWillExpire() {
    if let contentHandler, let bestAttemptContent {
      contentHandler(bestAttemptContent)
    }
  }

  private func matrixEventURL(
    homeserver: String,
    roomId: String,
    eventId: String
  ) -> URL? {
    guard var url = URL(string: homeserver) else { return nil }
    for component in ["_matrix", "client", "v3", "rooms", roomId, "event", eventId] {
      url.appendPathComponent(component)
    }
    return url
  }

  private func decrypt(
    sessionId: String,
    ciphertext: String,
    userId: String
  ) -> String? {
    guard let pickle = sessionPickle(sessionId: sessionId) else { return nil }
    var pickleKey = Array(userId.utf8.prefix(32))
    pickleKey.append(contentsOf: repeatElement(0, count: 32 - pickleKey.count))

    let result = pickle.withCString { picklePointer in
      ciphertext.withCString { ciphertextPointer in
        pickleKey.withUnsafeBufferPointer { keyPointer in
          ios_decrypt_event(picklePointer, keyPointer.baseAddress, ciphertextPointer)
        }
      }
    }
    defer { ios_free_result(result) }
    guard result.error == nil, let plaintext = result.plaintext else { return nil }

    let plaintextString = String(cString: plaintext)
    guard
      let data = plaintextString.data(using: .utf8),
      let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let content = event["content"] as? [String: Any],
      let body = content["body"] as? String
    else {
      return nil
    }
    return body
  }

  private func sessionPickle(sessionId: String) -> String? {
    guard
      let container = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: Self.appGroup
      )
    else {
      return nil
    }

    var database: OpaquePointer?
    let databasePath = container.appendingPathComponent("patrick_messenger.sqlite").path
    guard
      sqlite3_open_v2(
        databasePath,
        &database,
        SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
        nil
      ) == SQLITE_OK,
      let database
    else {
      return nil
    }
    defer { sqlite3_close(database) }

    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(
        database,
        "SELECT v FROM box_inbound_group_session WHERE k = ? LIMIT 1",
        -1,
        &statement,
        nil
      ) == SQLITE_OK,
      let statement
    else {
      return nil
    }
    defer { sqlite3_finalize(statement) }
    sqlite3_bind_text(statement, 1, sessionId, -1, sqliteTransient)
    guard
      sqlite3_step(statement) == SQLITE_ROW,
      let jsonText = sqlite3_column_text(statement, 0)
    else {
      return nil
    }

    let jsonString = String(cString: jsonText)
    guard
      let data = jsonString.data(using: .utf8),
      let storedSession = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      return nil
    }
    return storedSession["pickle"] as? String
  }

  private func readableSender(_ matrixId: String?) -> String {
    guard let matrixId else { return "Patrick Messenger" }
    let localpart = matrixId
      .split(separator: ":", maxSplits: 1)
      .first?
      .trimmingCharacters(in: CharacterSet(charactersIn: "@")) ?? matrixId
    return localpart
      .replacingOccurrences(of: "_", with: " ")
      .split(separator: " ")
      .map { $0.prefix(1).uppercased() + $0.dropFirst() }
      .joined(separator: " ")
  }
}
