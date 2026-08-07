import Darwin
import Intents
import SQLite3
import flutter_vodozemac

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Handles a CarPlay/Siri "send a message" request without the main app
/// running. Mirrors NotificationService.swift's proven pattern for reaching
/// the app's Matrix session from an extension process: credentials come
/// from `UserDefaults` in the shared App Group (populated by
/// `AppDelegate.configureNotificationExtension`), and the encrypted session
/// state is read directly from the same SQLite database the main app uses.
///
/// Unlike NotificationService (decrypt-only, no shared mutable state),
/// sending here advances the room's outbound Megolm session -- reusing a
/// message index is a real plaintext-recovery bug, not just a data race --
/// so every step from reading the session to persisting its advanced state
/// happens under a real file lock (`outbound_session.lock`, in the same
/// shared container) that `MatrixMessageSender` on the Dart side takes for
/// the identical reason.
final class IntentHandler: INExtension, INSendMessageIntentHandling {
  private static let appGroup = "group.com.patricklamphier.patrickMessenger"

  override func handler(for intent: INIntent) -> Any {
    return self
  }

  // MARK: - INSendMessageIntentHandling

  func resolveRecipients(
    for intent: INSendMessageIntent,
    with completion: @escaping ([INSendMessageRecipientResolutionResult]) -> Void
  ) {
    guard let recipients = intent.recipients, !recipients.isEmpty else {
      completion([INSendMessageRecipientResolutionResult.needsValue()])
      return
    }
    completion(recipients.map { .success(with: $0) })
  }

  func resolveContent(
    for intent: INSendMessageIntent,
    with completion: @escaping (INStringResolutionResult) -> Void
  ) {
    guard let text = intent.content, !text.isEmpty else {
      completion(.needsValue())
      return
    }
    completion(.success(with: text))
  }

  func confirm(
    intent: INSendMessageIntent,
    completion: @escaping (INSendMessageIntentResponse) -> Void
  ) {
    guard
      roomId(for: intent) != nil,
      let defaults = UserDefaults(suiteName: Self.appGroup),
      defaults.string(forKey: "homeserver") != nil,
      defaults.string(forKey: "accessToken") != nil,
      defaults.string(forKey: "userId") != nil,
      defaults.string(forKey: "deviceId") != nil,
      defaults.string(forKey: "senderKey") != nil
    else {
      completion(INSendMessageIntentResponse(code: .failure, userActivity: nil))
      return
    }
    completion(INSendMessageIntentResponse(code: .ready, userActivity: nil))
  }

  func handle(
    intent: INSendMessageIntent,
    completion: @escaping (INSendMessageIntentResponse) -> Void
  ) {
    guard
      let roomId = roomId(for: intent),
      let text = intent.content,
      !text.isEmpty,
      let defaults = UserDefaults(suiteName: Self.appGroup),
      let homeserver = defaults.string(forKey: "homeserver"),
      let accessToken = defaults.string(forKey: "accessToken"),
      let userId = defaults.string(forKey: "userId"),
      let deviceId = defaults.string(forKey: "deviceId"),
      let senderKey = defaults.string(forKey: "senderKey")
    else {
      completion(INSendMessageIntentResponse(code: .failure, userActivity: nil))
      return
    }

    let succeeded = sendEncryptedMessage(
      roomId: roomId,
      body: text,
      userId: userId,
      deviceId: deviceId,
      senderKey: senderKey,
      homeserver: homeserver,
      accessToken: accessToken
    )
    completion(
      INSendMessageIntentResponse(code: succeeded ? .success : .failure, userActivity: nil)
    )
  }

  private func roomId(for intent: INSendMessageIntent) -> String? {
    intent.conversationIdentifier
  }

  // MARK: - Send

  private func sendEncryptedMessage(
    roomId: String,
    body: String,
    userId: String,
    deviceId: String,
    senderKey: String,
    homeserver: String,
    accessToken: String
  ) -> Bool {
    guard
      let container = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: Self.appGroup
      )
    else {
      return false
    }

    let lockPath = container.appendingPathComponent("outbound_session.lock").path
    guard let lockFD = Self.acquireLock(at: lockPath) else { return false }
    defer { Self.releaseLock(lockFD) }

    let databasePath = container.appendingPathComponent("patrick_messenger.sqlite").path
    var database: OpaquePointer?
    guard
      sqlite3_open_v2(
        databasePath,
        &database,
        SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
        nil
      ) == SQLITE_OK,
      let database
    else {
      return false
    }
    defer { sqlite3_close(database) }

    guard let pickle = Self.outboundPickle(database: database, roomId: roomId) else {
      return false
    }

    var pickleKey = Array(userId.utf8.prefix(32))
    pickleKey.append(contentsOf: repeatElement(0, count: 32 - pickleKey.count))

    guard
      let plaintextData = try? JSONSerialization.data(withJSONObject: [
        "type": "m.room.message",
        "content": [
          "msgtype": "m.text",
          "body": body,
        ],
        "room_id": roomId,
      ] as [String: Any]),
      let plaintext = String(data: plaintextData, encoding: .utf8)
    else {
      return false
    }

    let result = pickle.withCString { picklePointer in
      plaintext.withCString { plaintextPointer in
        pickleKey.withUnsafeBufferPointer { keyPointer in
          ios_encrypt_event(picklePointer, keyPointer.baseAddress, plaintextPointer)
        }
      }
    }
    defer { ios_free_encrypt_result(result) }
    guard
      result.error == nil,
      let ciphertextPointer = result.ciphertext,
      let advancedPicklePointer = result.advanced_pickle,
      let sessionIdPointer = result.session_id
    else {
      return false
    }
    let ciphertext = String(cString: ciphertextPointer)
    let advancedPickle = String(cString: advancedPicklePointer)
    let sessionId = String(cString: sessionIdPointer)

    // Persist the advanced ratchet state before sending, not after: if the
    // network call fails or this process is killed right after, the worst
    // outcome is an un-sent message, never a reused message index.
    guard
      Self.storeOutboundPickle(database: database, roomId: roomId, pickle: advancedPickle)
    else {
      return false
    }

    return Self.putEncryptedEvent(
      roomId: roomId,
      homeserver: homeserver,
      accessToken: accessToken,
      senderKey: senderKey,
      deviceId: deviceId,
      sessionId: sessionId,
      ciphertext: ciphertext
    )
  }

  /// Reads the raw JSON blob (`{room_id, pickle, device_ids, creation_time}`)
  /// stored for a room's outbound session -- matrix-dart-sdk's
  /// `storeOutboundGroupSession` schema.
  private static func outboundSessionRow(
    database: OpaquePointer,
    roomId: String
  ) -> [String: Any]? {
    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(
        database,
        "SELECT v FROM box_outbound_group_session WHERE k = ? LIMIT 1",
        -1,
        &statement,
        nil
      ) == SQLITE_OK,
      let statement
    else {
      return nil
    }
    defer { sqlite3_finalize(statement) }
    sqlite3_bind_text(statement, 1, roomId, -1, sqliteTransient)
    guard
      sqlite3_step(statement) == SQLITE_ROW,
      let jsonText = sqlite3_column_text(statement, 0),
      let data = String(cString: jsonText).data(using: .utf8),
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      return nil
    }
    return json
  }

  private static func outboundPickle(database: OpaquePointer, roomId: String) -> String? {
    outboundSessionRow(database: database, roomId: roomId)?["pickle"] as? String
  }

  private static func storeOutboundPickle(
    database: OpaquePointer,
    roomId: String,
    pickle: String
  ) -> Bool {
    // Preserve device_ids/creation_time from the existing row -- only the
    // pickle itself changed.
    var updated = outboundSessionRow(database: database, roomId: roomId) ?? [:]
    updated["room_id"] = roomId
    updated["pickle"] = pickle
    if updated["device_ids"] == nil { updated["device_ids"] = "[]" }
    if updated["creation_time"] == nil {
      updated["creation_time"] = Int(Date().timeIntervalSince1970 * 1000)
    }

    guard
      let updatedData = try? JSONSerialization.data(withJSONObject: updated),
      let updatedJSON = String(data: updatedData, encoding: .utf8)
    else {
      return false
    }

    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(
        database,
        "INSERT OR REPLACE INTO box_outbound_group_session (k, v) VALUES (?, ?)",
        -1,
        &statement,
        nil
      ) == SQLITE_OK,
      let statement
    else {
      return false
    }
    defer { sqlite3_finalize(statement) }
    sqlite3_bind_text(statement, 1, roomId, -1, sqliteTransient)
    sqlite3_bind_text(statement, 2, updatedJSON, -1, sqliteTransient)
    return sqlite3_step(statement) == SQLITE_DONE
  }

  private static func putEncryptedEvent(
    roomId: String,
    homeserver: String,
    accessToken: String,
    senderKey: String,
    deviceId: String,
    sessionId: String,
    ciphertext: String
  ) -> Bool {
    guard var url = URL(string: homeserver) else { return false }
    let txnId = "carplay-\(Int(Date().timeIntervalSince1970 * 1000))-\(Int.random(in: 0...999_999))"
    for component in ["_matrix", "client", "v3", "rooms", roomId, "send", "m.room.encrypted", txnId] {
      url.appendPathComponent(component)
    }

    let body: [String: Any] = [
      "algorithm": "m.megolm.v1.aes-sha2",
      "sender_key": senderKey,
      "ciphertext": ciphertext,
      "session_id": sessionId,
      "device_id": deviceId,
    ]
    guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return false }

    // SiriKit extensions get a limited execution budget, so this stays well
    // under it rather than using a generous network timeout.
    var request = URLRequest(url: url)
    request.httpMethod = "PUT"
    request.timeoutInterval = 8
    request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = bodyData

    let semaphore = DispatchSemaphore(value: 0)
    var succeeded = false
    URLSession.shared.dataTask(with: request) { _, response, _ in
      if let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) {
        succeeded = true
      }
      semaphore.signal()
    }.resume()
    _ = semaphore.wait(timeout: .now() + 9)
    return succeeded
  }

  // MARK: - Cross-process advisory lock

  private static func acquireLock(at path: String) -> Int32? {
    let fd = open(path, O_CREAT | O_RDWR, 0o600)
    guard fd >= 0 else { return nil }
    guard flock(fd, LOCK_EX) == 0 else {
      close(fd)
      return nil
    }
    return fd
  }

  private static func releaseLock(_ fd: Int32) {
    flock(fd, LOCK_UN)
    close(fd)
  }
}
