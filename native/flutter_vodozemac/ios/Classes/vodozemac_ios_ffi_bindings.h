#ifndef VODOZEMAC_IOS_FFI_BINDINGS_H
#define VODOZEMAC_IOS_FFI_BINDINGS_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * Result structure for iOS FFI decryption operations.
 * Contains the decrypted plaintext and error information.
 */
typedef struct {
    /** Decrypted plaintext (JSON string), or NULL on error */
    char* plaintext;
    /** Error message if operation failed, or NULL on success */
    char* error;
} IOSDecryptResult;

/**
 * Decrypt an encrypted message using a pickled session.
 * 
 * This function is designed for use in iOS Notification Extensions where you need
 * to decrypt messages without the main app running.
 * 
 * @param pickled_session Encrypted pickled session (vodozemac format)
 * @param pickle_key Pointer to 32-byte array containing the pickle key
 * @param ciphertext Base64 encoded encrypted message
 * 
 * @return IOSDecryptResult containing:
 *         - plaintext: The decrypted message (JSON string)
 *         - error: Error message if operation failed
 * 
 * @note Caller must free all non-NULL fields using ios_free_result()
 * 
 * @example
 * ```swift
 * let pickleKey: [UInt8] = ... // Your 32-byte pickle key
 * let pickledSession = "..." // Pickled session from storage
 * let ciphertext = "..." // Base64 encrypted message
 * 
 * let result = ios_decrypt_event(
 *     pickledSession,
 *     pickleKey,
 *     ciphertext
 * )
 * 
 * if result.error == nil {
 *     let plaintext = String(cString: result.plaintext!)
 *     print("Decrypted: \(plaintext)")
 * } else {
 *     let error = String(cString: result.error!)
 *     print("Operation failed: \(error)")
 * }
 * 
 * ios_free_result(result)
 * ```
 */
IOSDecryptResult ios_decrypt_event(
    const char* pickled_session,
    const uint8_t pickle_key[32],
    const char* ciphertext
);

/**
 * Result structure for iOS FFI encryption operations.
 * Contains the ciphertext and the outbound session's advanced pickle.
 */
typedef struct {
    /** Base64-encoded Megolm ciphertext, or NULL on error */
    char* ciphertext;
    /**
     * The outbound session's pickle after this call advanced its ratchet,
     * re-encrypted with the same pickle key, or NULL on error. The caller
     * MUST persist this back over the session it read (e.g. under a lock
     * shared with any other process that might also encrypt for this room),
     * so the next encrypt continues from the advanced state instead of
     * reusing a message index -- reusing an index is a real plaintext-
     * recovery bug for Megolm, not just a data race.
     */
    char* advanced_pickle;
    /**
     * The session's globally unique ID (base64), needed for the
     * `m.room.encrypted` event content's `session_id` field, or NULL on
     * error.
     */
    char* session_id;
    /** Error message if operation failed, or NULL on success */
    char* error;
} IOSEncryptResult;

/**
 * Encrypt a plaintext with a pickled *outbound* Megolm session.
 *
 * This function is designed for use in an iOS Intents Extension (e.g. for
 * CarPlay/Siri message sending) where you need to send an encrypted message
 * without the main app running.
 *
 * @param pickled_session Encrypted pickled outbound group session (vodozemac
 *        `GroupSession::pickle().encrypt(...)` format, matching what
 *        matrix-dart-sdk persists for a room's outbound Megolm session)
 * @param pickle_key Pointer to 32-byte array containing the pickle key
 * @param plaintext The event JSON to encrypt, as a UTF-8 C string
 *
 * @return IOSEncryptResult containing:
 *         - ciphertext: The base64-encoded Megolm message to send
 *         - advanced_pickle: The session's pickle after encrypting -- the
 *           caller MUST persist this so the ratchet position is never reused
 *         - error: Error message if operation failed
 *
 * @note Caller must free all non-NULL fields using ios_free_encrypt_result()
 *
 * @example
 * ```swift
 * let pickleKey: [UInt8] = ... // Your 32-byte pickle key
 * let pickledSession = "..." // This room's outbound session pickle from storage
 * let plaintext = "..." // The event JSON to encrypt
 *
 * let result = ios_encrypt_event(pickledSession, pickleKey, plaintext)
 *
 * if result.error == nil {
 *     let ciphertext = String(cString: result.ciphertext!)
 *     let advancedPickle = String(cString: result.advanced_pickle!)
 *     // Persist advancedPickle back to storage before releasing your lock.
 * } else {
 *     let error = String(cString: result.error!)
 *     print("Operation failed: \(error)")
 * }
 *
 * ios_free_encrypt_result(result)
 * ```
 */
IOSEncryptResult ios_encrypt_event(
    const char* pickled_session,
    const uint8_t pickle_key[32],
    const char* plaintext
);

/**
 * Free an IOSEncryptResult structure and all its fields.
 *
 * @param result Result structure to free
 */
void ios_free_encrypt_result(IOSEncryptResult result);

/**
 * Free a string allocated by this library.
 *
 * @param s String to free (can be NULL)
 */
void ios_free_string(char* s);

/**
 * Free an IOSDecryptResult structure and all its fields.
 * 
 * @param result Result structure to free
 */
void ios_free_result(IOSDecryptResult result);

#ifdef __cplusplus
}
#endif

#endif /* VODOZEMAC_IOS_FFI_BINDINGS_H */
