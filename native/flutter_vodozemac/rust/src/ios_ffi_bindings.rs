//! C-compatible FFI bindings for iOS
//! These functions can be called directly from Swift without flutter_rust_bridge

use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use vodozemac::megolm::{
    GroupSession, GroupSessionPickle, InboundGroupSession, InboundGroupSessionPickle,
    MegolmMessage,
};

/// Result structure for iOS FFI decryption operations
#[repr(C)]
pub struct IOSDecryptResult {
    /// Decrypted plaintext (JSON string), or NULL on error
    pub plaintext: *mut c_char,
    /// Error message if operation failed, or NULL on success
    pub error: *mut c_char,
}

/// Decrypt an encrypted message using a pickled session
/// 
/// # Arguments
/// * `pickled_session` - Encrypted pickled session (from vodozemac)
/// * `pickle_key` - Pointer to 32-byte pickle key array
/// * `ciphertext` - Base64 encoded encrypted message
///
/// # Returns
/// An IOSDecryptResult containing:
/// - plaintext: The decrypted message (JSON string)
/// - error: Error message if decryption failed
/// 
/// Caller must free all non-NULL fields using `ios_free_result`
#[no_mangle]
pub extern "C" fn ios_decrypt_event(
    pickled_session: *const c_char,
    pickle_key: *const [u8; 32],
    ciphertext: *const c_char,
) -> IOSDecryptResult {
    // Initialize result with nulls
    let mut result = IOSDecryptResult {
        plaintext: std::ptr::null_mut(),
        error: std::ptr::null_mut(),
    };

    // Safety check for null pointers
    if pickled_session.is_null() || pickle_key.is_null() || ciphertext.is_null() {
        result.error = create_c_string("Invalid input: null pointer provided");
        return result;
    }

    // Convert C strings to Rust strings
    let pickled_session_str = match unsafe { CStr::from_ptr(pickled_session).to_str() } {
        Ok(s) => s,
        Err(e) => {
            result.error = create_c_string(&format!("Invalid pickled_session string: {}", e));
            return result;
        }
    };

    let ciphertext_str = match unsafe { CStr::from_ptr(ciphertext).to_str() } {
        Ok(s) => s,
        Err(e) => {
            result.error = create_c_string(&format!("Invalid ciphertext string: {}", e));
            return result;
        }
    };

    // Attempt decryption
    match decrypt_event_internal(pickled_session_str, unsafe { *pickle_key }, ciphertext_str) {
        Ok(plaintext) => {
            result.plaintext = create_c_string(&plaintext);
        }
        Err(e) => {
            result.error = create_c_string(&format!("Decryption failed: {}", e));
        }
    }

    result
}

/// Result structure for iOS FFI encryption operations
#[repr(C)]
pub struct IOSEncryptResult {
    /// Base64-encoded Megolm ciphertext, or NULL on error
    pub ciphertext: *mut c_char,
    /// The outbound session's pickle after this encrypt call advanced its
    /// ratchet, re-encrypted with the same pickle key, or NULL on error.
    /// The caller MUST persist this back over the session it read, so the
    /// next encrypt (from any process) continues from the advanced state
    /// instead of reusing a message index.
    pub advanced_pickle: *mut c_char,
    /// The session's globally unique ID (base64), needed for the
    /// `m.room.encrypted` event content's `session_id` field, or NULL on
    /// error.
    pub session_id: *mut c_char,
    /// Error message if operation failed, or NULL on success
    pub error: *mut c_char,
}

/// Encrypt a plaintext with a pickled *outbound* Megolm session, returning
/// both the ciphertext and the session's advanced pickle.
///
/// # Arguments
/// * `pickled_session` - Encrypted pickled outbound group session (from
///   vodozemac's `GroupSession::pickle().encrypt(...)`, e.g. as persisted by
///   matrix-dart-sdk's `KeyManager` in `box_outbound_group_session`)
/// * `pickle_key` - Pointer to 32-byte pickle key array
/// * `plaintext` - The event JSON to encrypt, as a UTF-8 C string
///
/// # Returns
/// An IOSEncryptResult containing:
/// - ciphertext: The base64-encoded Megolm message
/// - advanced_pickle: The session's pickle after encrypting, which the
///   caller must persist so the ratchet position is never reused
/// - error: Error message if encryption failed
///
/// Caller must free all non-NULL fields using `ios_free_encrypt_result`
#[no_mangle]
pub extern "C" fn ios_encrypt_event(
    pickled_session: *const c_char,
    pickle_key: *const [u8; 32],
    plaintext: *const c_char,
) -> IOSEncryptResult {
    let mut result = IOSEncryptResult {
        ciphertext: std::ptr::null_mut(),
        advanced_pickle: std::ptr::null_mut(),
        session_id: std::ptr::null_mut(),
        error: std::ptr::null_mut(),
    };

    if pickled_session.is_null() || pickle_key.is_null() || plaintext.is_null() {
        result.error = create_c_string("Invalid input: null pointer provided");
        return result;
    }

    let pickled_session_str = match unsafe { CStr::from_ptr(pickled_session).to_str() } {
        Ok(s) => s,
        Err(e) => {
            result.error = create_c_string(&format!("Invalid pickled_session string: {}", e));
            return result;
        }
    };

    let plaintext_str = match unsafe { CStr::from_ptr(plaintext).to_str() } {
        Ok(s) => s,
        Err(e) => {
            result.error = create_c_string(&format!("Invalid plaintext string: {}", e));
            return result;
        }
    };

    match encrypt_event_internal(pickled_session_str, unsafe { *pickle_key }, plaintext_str) {
        Ok((ciphertext, advanced_pickle, session_id)) => {
            result.ciphertext = create_c_string(&ciphertext);
            result.advanced_pickle = create_c_string(&advanced_pickle);
            result.session_id = create_c_string(&session_id);
        }
        Err(e) => {
            result.error = create_c_string(&format!("Encryption failed: {}", e));
        }
    }

    result
}

/// Free an IOSEncryptResult structure
///
/// # Safety
/// Must only be called with results returned by ios_encrypt_event
#[no_mangle]
pub extern "C" fn ios_free_encrypt_result(result: IOSEncryptResult) {
    ios_free_string(result.ciphertext);
    ios_free_string(result.advanced_pickle);
    ios_free_string(result.session_id);
    ios_free_string(result.error);
}

/// Free a string allocated by this library
///
/// # Safety
/// Must only be called with strings returned by iOS FFI functions
#[no_mangle]
pub extern "C" fn ios_free_string(s: *mut c_char) {
    if !s.is_null() {
        unsafe {
            let _ = CString::from_raw(s);
        }
    }
}

/// Free an IOSDecryptResult structure
/// 
/// # Safety
/// Must only be called with results returned by ios_decrypt_event
#[no_mangle]
pub extern "C" fn ios_free_result(result: IOSDecryptResult) {
    ios_free_string(result.plaintext);
    ios_free_string(result.error);
}

/// Helper to create a C string, returns null on error
fn create_c_string(s: &str) -> *mut c_char {
    match CString::new(s) {
        Ok(c_str) => c_str.into_raw(),
        Err(_) => std::ptr::null_mut(),
    }
}

/// Internal decryption logic
fn decrypt_event_internal(
    pickled_session: &str,
    pickle_key: [u8; 32],
    ciphertext: &str,
) -> Result<String, Box<dyn std::error::Error>> {
    // Unpickle the session from vodozemac's encrypted pickle format
    let pickle = InboundGroupSessionPickle::from_encrypted(pickled_session, &pickle_key)?;
    let mut session = InboundGroupSession::from(pickle);

    // Parse the ciphertext
    let message = MegolmMessage::from_base64(ciphertext)?;

    // Decrypt the message
    let decrypted = session.decrypt(&message)?;

    // Convert plaintext bytes to UTF-8 string
    let plaintext = String::from_utf8(decrypted.plaintext)?;

    Ok(plaintext)
}

/// Internal encryption logic. Returns (base64 ciphertext, re-encrypted
/// advanced pickle, session ID).
fn encrypt_event_internal(
    pickled_session: &str,
    pickle_key: [u8; 32],
    plaintext: &str,
) -> Result<(String, String, String), Box<dyn std::error::Error>> {
    // Unpickle the outbound session from vodozemac's encrypted pickle format
    let pickle = GroupSessionPickle::from_encrypted(pickled_session, &pickle_key)?;
    let mut session = GroupSession::from(pickle);
    let session_id = session.session_id();

    // Encrypt, which advances the session's ratchet in place
    let message = session.encrypt(plaintext);
    let ciphertext = message.to_base64();

    // Re-pickle the now-advanced session so the caller can persist it,
    // guaranteeing the next encrypt (from any process) never reuses this
    // message index.
    let advanced_pickle = session.pickle().encrypt(&pickle_key);

    Ok((ciphertext, advanced_pickle, session_id))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::CString;
    use vodozemac::megolm::GroupSession;

    #[test]
    fn test_decrypt_matrix_event_with_pickle() {
        // Create a group session and encrypt a message
        let mut outbound_session = GroupSession::new(vodozemac::megolm::SessionConfig::version_1());
        let session_key = outbound_session.session_key();
        let plaintext = "Hello, iOS Notification Extension!";
        let ciphertext = outbound_session.encrypt(plaintext);

        // Create inbound session and pickle it using vodozemac native format
        let inbound_session = InboundGroupSession::new(
            &session_key,
            vodozemac::megolm::SessionConfig::version_1(),
        );
        let pickle_key: [u8; 32] = *b"01234567890123456789012345678901";
        let pickled = inbound_session.pickle().encrypt(&pickle_key);

        // Convert to C strings
        let pickled_c = CString::new(pickled.clone()).unwrap();
        let ciphertext_c = CString::new(ciphertext.to_base64()).unwrap();

        // Call the C function
        let result = ios_decrypt_event(
            pickled_c.as_ptr(),
            &pickle_key,
            ciphertext_c.as_ptr(),
        );

        // Check for success
        if !result.error.is_null() {
            let error_msg = unsafe { CStr::from_ptr(result.error).to_str().unwrap() };
            panic!("Decryption failed: {}", error_msg);
        }
        assert!(!result.plaintext.is_null(), "Expected plaintext");

        // Convert result back to Rust string
        let result_plaintext = unsafe { CStr::from_ptr(result.plaintext).to_str().unwrap() };
        assert_eq!(result_plaintext, plaintext);

        // Clean up
        ios_free_result(result);
    }

    #[test]
    fn test_decrypt_with_invalid_pickle() {
        let pickle_key: [u8; 32] = *b"0123456789012345678901234567890!";
        let invalid_pickle = CString::new("invalid_base64_pickle").unwrap();
        let ciphertext = CString::new("some_ciphertext").unwrap();

        let result = ios_decrypt_event(
            invalid_pickle.as_ptr(),
            &pickle_key,
            ciphertext.as_ptr(),
        );

        // Should have error
        assert!(!result.error.is_null());
        assert!(result.plaintext.is_null());

        ios_free_result(result);
    }

    #[test]
    fn test_encrypt_then_decrypt_round_trip() {
        let outbound_session = GroupSession::new(vodozemac::megolm::SessionConfig::version_1());
        let session_key = outbound_session.session_key();
        let pickle_key: [u8; 32] = *b"01234567890123456789012345678901";
        let pickled = outbound_session.pickle().encrypt(&pickle_key);

        let pickled_c = CString::new(pickled).unwrap();
        let plaintext = "Hello from CarPlay!";
        let plaintext_c = CString::new(plaintext).unwrap();

        let encrypt_result = ios_encrypt_event(pickled_c.as_ptr(), &pickle_key, plaintext_c.as_ptr());
        if !encrypt_result.error.is_null() {
            let error_msg = unsafe { CStr::from_ptr(encrypt_result.error).to_str().unwrap() };
            panic!("Encryption failed: {}", error_msg);
        }
        assert!(!encrypt_result.ciphertext.is_null());
        assert!(!encrypt_result.advanced_pickle.is_null());
        assert!(!encrypt_result.session_id.is_null());
        let session_id_str =
            unsafe { CStr::from_ptr(encrypt_result.session_id).to_str().unwrap() };
        assert_eq!(session_id_str, outbound_session.session_id());

        let ciphertext_str =
            unsafe { CStr::from_ptr(encrypt_result.ciphertext).to_str().unwrap() }.to_string();

        // An inbound session built from the *original* (pre-encrypt) session
        // key must be able to decrypt this, exactly as a real recipient
        // device would.
        let inbound_session = InboundGroupSession::new(
            &session_key,
            vodozemac::megolm::SessionConfig::version_1(),
        );
        let inbound_pickled = inbound_session.pickle().encrypt(&pickle_key);
        let inbound_pickled_c = CString::new(inbound_pickled).unwrap();
        let ciphertext_c = CString::new(ciphertext_str).unwrap();

        let decrypt_result =
            ios_decrypt_event(inbound_pickled_c.as_ptr(), &pickle_key, ciphertext_c.as_ptr());
        if !decrypt_result.error.is_null() {
            let error_msg = unsafe { CStr::from_ptr(decrypt_result.error).to_str().unwrap() };
            panic!("Decryption failed: {}", error_msg);
        }
        let decrypted_plaintext =
            unsafe { CStr::from_ptr(decrypt_result.plaintext).to_str().unwrap() };
        assert_eq!(decrypted_plaintext, plaintext);

        // The advanced pickle must reflect a ratchet that moved forward, so
        // a second encrypt from the advanced state can never reuse this
        // message index.
        let advanced_pickle_str =
            unsafe { CStr::from_ptr(encrypt_result.advanced_pickle).to_str().unwrap() }
                .to_string();
        let advanced_pickle_key = *b"01234567890123456789012345678901";
        let reloaded = GroupSession::from(
            GroupSessionPickle::from_encrypted(&advanced_pickle_str, &advanced_pickle_key)
                .unwrap(),
        );
        assert_eq!(reloaded.message_index(), outbound_session.message_index() + 1);

        ios_free_result(decrypt_result);
        ios_free_encrypt_result(encrypt_result);
    }

    #[test]
    fn test_encrypt_with_invalid_pickle() {
        let pickle_key: [u8; 32] = *b"0123456789012345678901234567890!";
        let invalid_pickle = CString::new("invalid_base64_pickle").unwrap();
        let plaintext = CString::new("some plaintext").unwrap();

        let result = ios_encrypt_event(invalid_pickle.as_ptr(), &pickle_key, plaintext.as_ptr());

        assert!(!result.error.is_null());
        assert!(result.ciphertext.is_null());
        assert!(result.advanced_pickle.is_null());
        assert!(result.session_id.is_null());

        ios_free_encrypt_result(result);
    }
}
