// Native layer of the ADB client: RSA keys, sockets, TLS and wireless-debugging pairing.
// Implemented in C on top of BoringSSL (the same crypto library used by AOSP's adb),
// exposed to Swift with opaque types only so no OpenSSL header leaks into Swift.

#ifndef ADB_NATIVE_H
#define ADB_NATIVE_H

#include <stddef.h>
#include <stdint.h>

typedef struct adb_key adb_key;
typedef struct adb_tls adb_tls;

// Keys: PEM (PKCS#8) RSA-2048 private key, compatible with the ~/.android/adbkey file.
adb_key *adb_key_load_or_create(const char *path, char *err, size_t errlen);
adb_key *adb_key_generate_to(const char *path, char *err, size_t errlen);
void adb_key_free(adb_key *key);
// Public key in Android format ("<base64> <name>"). Returns string length or -1.
int adb_key_public_string(const adb_key *key, const char *name, char *out, size_t outlen);
// Signs the 20-byte AUTH token. Returns signature length or -1.
int adb_key_sign_token(const adb_key *key, const uint8_t *token, size_t token_len, uint8_t *sig, size_t sig_cap);

// TCP sockets (blocking, SIGPIPE disabled).
int adb_tcp_connect(const char *host, int port, int timeout_ms, char *err, size_t errlen);
int adb_fd_set_timeout(int fd, int timeout_ms);
void adb_fd_shutdown(int fd);
void adb_fd_close(int fd);
// Returns bytes read, 0 on EOF, -1 on error/timeout.
int adb_fd_read(int fd, uint8_t *buf, size_t len);
// Returns 0 on success, -1 on error.
int adb_fd_write_all(int fd, const uint8_t *buf, size_t len);

// TLS 1.3 client over an already connected socket, authenticated with the adb key.
adb_tls *adb_tls_handshake(int fd, const adb_key *key, char *err, size_t errlen);
int adb_tls_read(adb_tls *tls, uint8_t *buf, size_t len);
int adb_tls_write_all(adb_tls *tls, const uint8_t *buf, size_t len);
void adb_tls_free(adb_tls *tls);

// Wireless debugging pairing (Android 11+): TLS + SPAKE2 + AES-128-GCM exchange of PeerInfo.
// On success returns 0 and writes the device's peer info (its GUID) to peer_out.
int adb_pair(const char *host, int port, const char *code, const adb_key *key, const char *name,
             char *peer_out, size_t peer_cap, char *err, size_t errlen);

#endif
