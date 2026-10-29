#include "AdbNative.h"

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>

#include <openssl/aead.h>
#include <openssl/base64.h>
#include <openssl/bn.h>
#include <openssl/curve25519.h>
#include <openssl/digest.h>
#include <openssl/err.h>
#include <openssl/evp.h>
#include <openssl/hkdf.h>
#include <openssl/pem.h>
#include <openssl/rsa.h>
#include <openssl/ssl.h>
#include <openssl/x509.h>

struct adb_key {
    EVP_PKEY *pkey;
    RSA *rsa;
    X509 *cert;
};

struct adb_tls {
    SSL_CTX *ctx;
    SSL *ssl;
};

static void set_err(char *err, size_t errlen, const char *fmt, ...) {
    if (!err || errlen == 0) return;
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(err, errlen, fmt, ap);
    va_end(ap);
}

static void append_ssl_err(char *err, size_t errlen) {
    unsigned long e = ERR_get_error();
    if (!err || errlen == 0 || e == 0) return;
    size_t n = strlen(err);
    if (n + 3 >= errlen) return;
    err[n] = ':';
    err[n + 1] = ' ';
    ERR_error_string_n(e, err + n + 2, errlen - n - 2);
}

// MARK: - Keys

static X509 *make_certificate(EVP_PKEY *pkey) {
    X509 *x = X509_new();
    if (!x) return NULL;
    X509_set_version(x, 2);
    ASN1_INTEGER_set(X509_get_serialNumber(x), 1);
    X509_gmtime_adj(X509_getm_notBefore(x), 0);
    X509_gmtime_adj(X509_getm_notAfter(x), 10L * 365 * 24 * 3600);
    X509_set_pubkey(x, pkey);
    X509_NAME *name = X509_get_subject_name(x);
    X509_NAME_add_entry_by_txt(name, "C", MBSTRING_ASC, (const uint8_t *)"US", -1, -1, 0);
    X509_NAME_add_entry_by_txt(name, "O", MBSTRING_ASC, (const uint8_t *)"Android", -1, -1, 0);
    X509_NAME_add_entry_by_txt(name, "CN", MBSTRING_ASC, (const uint8_t *)"Adb", -1, -1, 0);
    X509_set_issuer_name(x, name);
    if (!X509_sign(x, pkey, EVP_sha256())) {
        X509_free(x);
        return NULL;
    }
    return x;
}

static adb_key *key_from_pkey(EVP_PKEY *pkey, char *err, size_t errlen) {
    adb_key *k = calloc(1, sizeof(*k));
    if (!k) {
        EVP_PKEY_free(pkey);
        return NULL;
    }
    k->pkey = pkey;
    k->rsa = EVP_PKEY_get1_RSA(pkey);
    if (!k->rsa) {
        set_err(err, errlen, "La chiave non è RSA");
        adb_key_free(k);
        return NULL;
    }
    k->cert = make_certificate(pkey);
    if (!k->cert) {
        set_err(err, errlen, "Creazione certificato fallita");
        append_ssl_err(err, errlen);
        adb_key_free(k);
        return NULL;
    }
    return k;
}

adb_key *adb_key_load_or_create(const char *path, char *err, size_t errlen) {
    FILE *f = fopen(path, "r");
    if (f) {
        EVP_PKEY *pkey = PEM_read_PrivateKey(f, NULL, NULL, NULL);
        fclose(f);
        if (pkey) return key_from_pkey(pkey, err, errlen);
    }
    return adb_key_generate_to(path, err, errlen);
}

adb_key *adb_key_generate_to(const char *path, char *err, size_t errlen) {
    RSA *rsa = RSA_new();
    BIGNUM *e = BN_new();
    EVP_PKEY *pkey = EVP_PKEY_new();
    if (!rsa || !e || !pkey || !BN_set_word(e, RSA_F4) || !RSA_generate_key_ex(rsa, 2048, e, NULL) ||
        !EVP_PKEY_assign_RSA(pkey, rsa)) {
        set_err(err, errlen, "Generazione chiave RSA fallita");
        append_ssl_err(err, errlen);
        BN_free(e);
        if (pkey && EVP_PKEY_id(pkey) == EVP_PKEY_RSA) {
            EVP_PKEY_free(pkey);
        } else {
            RSA_free(rsa);
            EVP_PKEY_free(pkey);
        }
        return NULL;
    }
    BN_free(e);

    FILE *f = fopen(path, "w");
    if (!f || !PEM_write_PrivateKey(f, pkey, NULL, NULL, 0, NULL, NULL)) {
        if (f) fclose(f);
        set_err(err, errlen, "Impossibile salvare la chiave in %s", path);
        EVP_PKEY_free(pkey);
        return NULL;
    }
    fclose(f);
    return key_from_pkey(pkey, err, errlen);
}

void adb_key_free(adb_key *key) {
    if (!key) return;
    X509_free(key->cert);
    RSA_free(key->rsa);
    EVP_PKEY_free(key->pkey);
    free(key);
}

static void put_le32(uint8_t *p, uint32_t v) {
    p[0] = (uint8_t)v;
    p[1] = (uint8_t)(v >> 8);
    p[2] = (uint8_t)(v >> 16);
    p[3] = (uint8_t)(v >> 24);
}

// Android RSAPublicKey layout: len(words) | n0inv | modulus LE | rr LE | exponent.
#define ANDROID_PUBKEY_WORDS 64
#define ANDROID_PUBKEY_BYTES (ANDROID_PUBKEY_WORDS * 4)
#define ANDROID_PUBKEY_SIZE (4 + 4 + ANDROID_PUBKEY_BYTES + ANDROID_PUBKEY_BYTES + 4)

int adb_key_public_string(const adb_key *key, const char *name, char *out, size_t outlen) {
    const BIGNUM *n = RSA_get0_n(key->rsa);
    const BIGNUM *e = RSA_get0_e(key->rsa);
    uint8_t bin[ANDROID_PUBKEY_SIZE];
    int ok = 0;

    BN_CTX *ctx = BN_CTX_new();
    BIGNUM *r32 = BN_new(), *n0inv = BN_new(), *rr = BN_new();
    if (ctx && r32 && n0inv && rr && BN_num_bytes(n) == ANDROID_PUBKEY_BYTES &&
        BN_set_bit(r32, 32) && BN_mod(n0inv, n, r32, ctx) &&
        BN_mod_inverse(n0inv, n0inv, r32, ctx) != NULL && BN_sub(n0inv, r32, n0inv) &&
        BN_set_bit(rr, ANDROID_PUBKEY_BYTES * 8 * 2) && BN_mod(rr, rr, n, ctx)) {
        put_le32(bin, ANDROID_PUBKEY_WORDS);
        put_le32(bin + 4, (uint32_t)BN_get_word(n0inv));
        ok = BN_bn2le_padded(bin + 8, ANDROID_PUBKEY_BYTES, n) &&
             BN_bn2le_padded(bin + 8 + ANDROID_PUBKEY_BYTES, ANDROID_PUBKEY_BYTES, rr);
        put_le32(bin + 8 + 2 * ANDROID_PUBKEY_BYTES, (uint32_t)BN_get_word(e));
    }
    BN_free(r32);
    BN_free(n0inv);
    BN_free(rr);
    BN_CTX_free(ctx);
    if (!ok) return -1;

    size_t b64len = 0;
    if (!EVP_EncodedLength(&b64len, sizeof(bin))) return -1;
    size_t namelen = strlen(name);
    if (b64len + 1 + namelen + 1 > outlen) return -1;
    size_t written = EVP_EncodeBlock((uint8_t *)out, bin, sizeof(bin));
    out[written] = ' ';
    memcpy(out + written + 1, name, namelen);
    out[written + 1 + namelen] = '\0';
    return (int)(written + 1 + namelen);
}

int adb_key_sign_token(const adb_key *key, const uint8_t *token, size_t token_len, uint8_t *sig, size_t sig_cap) {
    unsigned siglen = 0;
    if (sig_cap < RSA_size(key->rsa)) return -1;
    // adbd verifies the token as if it were a SHA-1 digest.
    if (!RSA_sign(NID_sha1, token, token_len, sig, &siglen, key->rsa)) return -1;
    return (int)siglen;
}

// MARK: - Sockets

int adb_tcp_connect(const char *host, int port, int timeout_ms, char *err, size_t errlen) {
    struct addrinfo hints;
    struct addrinfo *res = NULL;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    char portstr[16];
    snprintf(portstr, sizeof(portstr), "%d", port);

    int rc = getaddrinfo(host, portstr, &hints, &res);
    if (rc != 0) {
        set_err(err, errlen, "Impossibile risolvere %s: %s", host, gai_strerror(rc));
        return -1;
    }

    int fd = -1;
    int lasterr = ECONNREFUSED;
    for (struct addrinfo *ai = res; ai; ai = ai->ai_next) {
        fd = socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
        if (fd < 0) {
            lasterr = errno;
            continue;
        }
        int one = 1;
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
        int flags = fcntl(fd, F_GETFL, 0);
        fcntl(fd, F_SETFL, flags | O_NONBLOCK);

        rc = connect(fd, ai->ai_addr, ai->ai_addrlen);
        if (rc < 0 && errno == EINPROGRESS) {
            struct pollfd p = {fd, POLLOUT, 0};
            int pr;
            do {
                pr = poll(&p, 1, timeout_ms);
            } while (pr < 0 && errno == EINTR);
            if (pr == 1) {
                int soerr = 0;
                socklen_t sl = sizeof(soerr);
                getsockopt(fd, SOL_SOCKET, SO_ERROR, &soerr, &sl);
                rc = soerr == 0 ? 0 : -1;
                if (soerr) lasterr = soerr;
            } else {
                lasterr = pr == 0 ? ETIMEDOUT : errno;
                rc = -1;
            }
        } else if (rc < 0) {
            lasterr = errno;
        }

        if (rc == 0) {
            fcntl(fd, F_SETFL, flags);
            break;
        }
        close(fd);
        fd = -1;
    }
    freeaddrinfo(res);

    if (fd < 0) set_err(err, errlen, "Connessione a %s:%d fallita: %s", host, port, strerror(lasterr));
    return fd;
}

int adb_fd_set_timeout(int fd, int timeout_ms) {
    struct timeval tv;
    tv.tv_sec = timeout_ms / 1000;
    tv.tv_usec = (timeout_ms % 1000) * 1000;
    return setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
}

void adb_fd_shutdown(int fd) { shutdown(fd, SHUT_RDWR); }

void adb_fd_close(int fd) { close(fd); }

int adb_fd_read(int fd, uint8_t *buf, size_t len) {
    ssize_t r;
    do {
        r = recv(fd, buf, len, 0);
    } while (r < 0 && errno == EINTR);
    return r < 0 ? -1 : (int)r;
}

int adb_fd_write_all(int fd, const uint8_t *buf, size_t len) {
    size_t sent = 0;
    while (sent < len) {
        ssize_t w = send(fd, buf + sent, len - sent, 0);
        if (w < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        sent += (size_t)w;
    }
    return 0;
}

// MARK: - TLS

static enum ssl_verify_result_t accept_any_peer(SSL *ssl, uint8_t *out_alert) {
    // As in adb: the server certificate is self-signed; trust is established by pairing.
    (void)ssl;
    (void)out_alert;
    return ssl_verify_ok;
}

adb_tls *adb_tls_handshake(int fd, const adb_key *key, char *err, size_t errlen) {
    adb_tls *t = calloc(1, sizeof(*t));
    if (!t) return NULL;
    t->ctx = SSL_CTX_new(TLS_method());
    if (!t->ctx || !SSL_CTX_set_min_proto_version(t->ctx, TLS1_3_VERSION) ||
        !SSL_CTX_set_max_proto_version(t->ctx, TLS1_3_VERSION) ||
        !SSL_CTX_use_certificate(t->ctx, key->cert) || !SSL_CTX_use_PrivateKey(t->ctx, key->pkey)) {
        set_err(err, errlen, "Inizializzazione TLS fallita");
        append_ssl_err(err, errlen);
        adb_tls_free(t);
        return NULL;
    }
    SSL_CTX_set_custom_verify(t->ctx, SSL_VERIFY_PEER, accept_any_peer);
    t->ssl = SSL_new(t->ctx);
    if (!t->ssl || !SSL_set_fd(t->ssl, fd) || SSL_connect(t->ssl) != 1) {
        set_err(err, errlen, "Handshake TLS fallito (il dispositivo è accoppiato con questa app?)");
        append_ssl_err(err, errlen);
        adb_tls_free(t);
        return NULL;
    }
    return t;
}

int adb_tls_read(adb_tls *tls, uint8_t *buf, size_t len) {
    int r = SSL_read(tls->ssl, buf, len > 0x7fffffff ? 0x7fffffff : (int)len);
    if (r > 0) return r;
    int e = SSL_get_error(tls->ssl, r);
    ERR_clear_error();
    return e == SSL_ERROR_ZERO_RETURN ? 0 : -1;
}

int adb_tls_write_all(adb_tls *tls, const uint8_t *buf, size_t len) {
    size_t sent = 0;
    while (sent < len) {
        size_t chunk = len - sent;
        if (chunk > 0x7fffffff) chunk = 0x7fffffff;
        int w = SSL_write(tls->ssl, buf + sent, (int)chunk);
        if (w <= 0) {
            ERR_clear_error();
            return -1;
        }
        sent += (size_t)w;
    }
    return 0;
}

void adb_tls_free(adb_tls *tls) {
    if (!tls) return;
    SSL_free(tls->ssl);
    SSL_CTX_free(tls->ctx);
    free(tls);
}

// MARK: - Pairing (mirrors AOSP adb/pairing_auth and adb/pairing_connection)

#define PAIRING_HEADER_VERSION 1
#define PAIRING_MSG_SPAKE2 0
#define PAIRING_MSG_PEER_INFO 1
#define PEER_INFO_SIZE 8192
#define PEER_INFO_RSA_PUB_KEY 0
#define EXPORTED_KEY_SIZE 64
#define GCM_TAG_SIZE 16

// 10 bytes: "adb-label" plus its terminating NUL (adbd includes the NUL in the label).
static const char kExportedKeyLabel[] = "adb-label";
static const uint8_t kClientName[] = "adb pair client";
static const uint8_t kServerName[] = "adb pair server";
static const uint8_t kHkdfInfo[] = "adb pairing_auth aes-128-gcm key";

static int tls_read_full(adb_tls *t, uint8_t *buf, size_t len) {
    size_t got = 0;
    while (got < len) {
        int r = adb_tls_read(t, buf + got, len - got);
        if (r <= 0) return -1;
        got += (size_t)r;
    }
    return 0;
}

static int write_packet(adb_tls *t, uint8_t type, const uint8_t *payload, uint32_t len) {
    uint8_t hdr[6] = {PAIRING_HEADER_VERSION, type, (uint8_t)(len >> 24), (uint8_t)(len >> 16),
                      (uint8_t)(len >> 8), (uint8_t)len};
    if (adb_tls_write_all(t, hdr, sizeof(hdr)) != 0) return -1;
    return adb_tls_write_all(t, payload, len);
}

static int read_packet(adb_tls *t, uint8_t type, uint8_t *buf, size_t cap, size_t *out_len) {
    uint8_t hdr[6];
    if (tls_read_full(t, hdr, sizeof(hdr)) != 0) return -1;
    uint32_t len = ((uint32_t)hdr[2] << 24) | ((uint32_t)hdr[3] << 16) | ((uint32_t)hdr[4] << 8) | hdr[5];
    if (hdr[0] != PAIRING_HEADER_VERSION || hdr[1] != type || len > cap) return -1;
    if (tls_read_full(t, buf, len) != 0) return -1;
    *out_len = len;
    return 0;
}

static int aes_gcm(int encrypt, const uint8_t key[16], uint64_t sequence, const uint8_t *in, size_t in_len,
                   uint8_t *out, size_t out_cap, size_t *out_len) {
    EVP_AEAD_CTX ctx;
    if (!EVP_AEAD_CTX_init(&ctx, EVP_aead_aes_128_gcm(), key, 16, EVP_AEAD_DEFAULT_TAG_LENGTH, NULL)) return -1;
    uint8_t nonce[12] = {0};
    for (int i = 0; i < 8; i++) nonce[i] = (uint8_t)(sequence >> (8 * i));
    int ok = encrypt ? EVP_AEAD_CTX_seal(&ctx, out, out_len, out_cap, nonce, sizeof(nonce), in, in_len, NULL, 0)
                     : EVP_AEAD_CTX_open(&ctx, out, out_len, out_cap, nonce, sizeof(nonce), in, in_len, NULL, 0);
    EVP_AEAD_CTX_cleanup(&ctx);
    return ok ? 0 : -1;
}

int adb_pair(const char *host, int port, const char *code, const adb_key *key, const char *name,
             char *peer_out, size_t peer_cap, char *err, size_t errlen) {
    int result = -1;
    adb_tls *t = NULL;
    SPAKE2_CTX *spake = NULL;
    uint8_t *password = NULL;
    uint8_t *peer_info = NULL;
    uint8_t *packet = NULL;
    uint8_t *decrypted = NULL;

    int fd = adb_tcp_connect(host, port, 10000, err, errlen);
    if (fd < 0) return -1;
    adb_fd_set_timeout(fd, 30000);

    t = adb_tls_handshake(fd, key, err, errlen);
    if (!t) goto done;

    uint8_t exported[EXPORTED_KEY_SIZE];
    if (!SSL_export_keying_material(t->ssl, exported, sizeof(exported), kExportedKeyLabel,
                                    sizeof(kExportedKeyLabel), NULL, 0, 0)) {
        set_err(err, errlen, "Esportazione chiave TLS fallita");
        goto done;
    }

    size_t code_len = strlen(code);
    password = malloc(code_len + EXPORTED_KEY_SIZE);
    if (!password) goto done;
    memcpy(password, code, code_len);
    memcpy(password + code_len, exported, EXPORTED_KEY_SIZE);

    spake = SPAKE2_CTX_new(spake2_role_alice, kClientName, sizeof(kClientName), kServerName, sizeof(kServerName));
    uint8_t my_msg[SPAKE2_MAX_MSG_SIZE];
    size_t my_msg_len = 0;
    if (!spake ||
        !SPAKE2_generate_msg(spake, my_msg, &my_msg_len, sizeof(my_msg), password, code_len + EXPORTED_KEY_SIZE)) {
        set_err(err, errlen, "Inizializzazione SPAKE2 fallita");
        goto done;
    }
    if (write_packet(t, PAIRING_MSG_SPAKE2, my_msg, (uint32_t)my_msg_len) != 0) {
        set_err(err, errlen, "Invio messaggio di accoppiamento fallito");
        goto done;
    }

    uint8_t their_msg[SPAKE2_MAX_MSG_SIZE];
    size_t their_msg_len = 0;
    if (read_packet(t, PAIRING_MSG_SPAKE2, their_msg, sizeof(their_msg), &their_msg_len) != 0) {
        set_err(err, errlen, "Il dispositivo ha chiuso la connessione durante l'accoppiamento");
        goto done;
    }

    uint8_t key_material[SPAKE2_MAX_KEY_SIZE];
    size_t key_material_len = 0;
    if (!SPAKE2_process_msg(spake, key_material, &key_material_len, sizeof(key_material), their_msg, their_msg_len)) {
        set_err(err, errlen, "Codice di accoppiamento errato");
        goto done;
    }

    uint8_t aes_key[16];
    if (!HKDF(aes_key, sizeof(aes_key), EVP_sha256(), key_material, key_material_len, NULL, 0, kHkdfInfo,
              sizeof(kHkdfInfo) - 1)) {
        set_err(err, errlen, "Derivazione chiave fallita");
        goto done;
    }

    peer_info = calloc(1, PEER_INFO_SIZE);
    packet = malloc(PEER_INFO_SIZE + GCM_TAG_SIZE);
    decrypted = malloc(PEER_INFO_SIZE + GCM_TAG_SIZE);
    if (!peer_info || !packet || !decrypted) goto done;

    peer_info[0] = PEER_INFO_RSA_PUB_KEY;
    if (adb_key_public_string(key, name, (char *)peer_info + 1, PEER_INFO_SIZE - 1) < 0) {
        set_err(err, errlen, "Chiave pubblica non valida");
        goto done;
    }

    size_t enc_len = 0;
    if (aes_gcm(1, aes_key, 0, peer_info, PEER_INFO_SIZE, packet, PEER_INFO_SIZE + GCM_TAG_SIZE, &enc_len) != 0 ||
        write_packet(t, PAIRING_MSG_PEER_INFO, packet, (uint32_t)enc_len) != 0) {
        set_err(err, errlen, "Invio della chiave pubblica fallito");
        goto done;
    }

    size_t in_len = 0, dec_len = 0;
    if (read_packet(t, PAIRING_MSG_PEER_INFO, packet, PEER_INFO_SIZE + GCM_TAG_SIZE, &in_len) != 0) {
        set_err(err, errlen, "Il dispositivo ha rifiutato l'accoppiamento (codice errato?)");
        goto done;
    }
    if (aes_gcm(0, aes_key, 0, packet, in_len, decrypted, PEER_INFO_SIZE + GCM_TAG_SIZE, &dec_len) != 0 ||
        dec_len < 1) {
        set_err(err, errlen, "Risposta del dispositivo non decifrabile (codice errato?)");
        goto done;
    }

    if (peer_out && peer_cap > 0) {
        size_t n = strnlen((const char *)decrypted + 1, dec_len - 1);
        if (n >= peer_cap) n = peer_cap - 1;
        memcpy(peer_out, decrypted + 1, n);
        peer_out[n] = '\0';
    }
    result = 0;

done:
    SPAKE2_CTX_free(spake);
    free(password);
    free(peer_info);
    free(packet);
    free(decrypted);
    if (t) {
        SSL_shutdown(t->ssl);
        adb_tls_free(t);
    }
    close(fd);
    return result;
}
