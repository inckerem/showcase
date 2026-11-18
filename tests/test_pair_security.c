#include <stdarg.h>
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <Security/SecRandom.h>

/* Scriptable RNG: lets a test pin the server's salt and b so a known-answer
 * vector (with salt[0] == 0x00) runs on every build instead of 1 in 256. */
typedef struct { const uint8_t *data; size_t len; } rng_script_t;
static rng_script_t test_rng_queue[4];
static int test_rng_count;

static int test_random_bytes(SecRandomRef rnd, size_t count, void *bytes) {
    if (test_rng_count > 0) {
        assert(test_rng_queue[0].len == count);
        memcpy(bytes, test_rng_queue[0].data, count);
        test_rng_count--;
        memmove(test_rng_queue, test_rng_queue + 1,
                sizeof(test_rng_queue[0]) * (size_t)test_rng_count);
        return errSecSuccess;
    }
    return SecRandomCopyBytes(rnd, count, bytes);
}
#define SecRandomCopyBytes test_random_bytes

#include "../source/carplay_pair.c"

int showcase_service_log_printf(const char *format, ...) { (void)format; return 0; }
__thread bool showcase_preauth_quiet = false;

#define SRP_N_BYTES 384  /* 3072-bit group */

/* Independent client primitives. Everything protocol-shaped (SRP x/k/u/M/H_AMK
 * byte layout and padding, HKDF labels, ChaCha nonce layout) is written out
 * here from the spec instead of calling the server's own helpers, so a format
 * regression in carplay_pair.c makes the server disagree with this client
 * (as it would with a real iPhone) instead of changing both sides at once. */

typedef struct { const void *p; size_t n; } part_t;

static void sha512_parts(uint8_t out[64], const part_t *parts, int count) {
    crypto_sha512_ctx c;
    crypto_sha512_init(&c);
    for (int i = 0; i < count; i++) crypto_sha512_update(&c, parts[i].p, parts[i].n);
    crypto_sha512_final(&c, out);
}

static void bn_pad(const BIGNUM *n, uint8_t out[SRP_N_BYTES]) {
    int len = BN_num_bytes(n);
    assert(len > 0 && len <= SRP_N_BYTES);
    memset(out, 0, SRP_N_BYTES);
    assert(BN_bn2bin(n, out + (SRP_N_BYTES - len)) == len);
}

static void client_hkdf(const uint8_t *ikm, size_t ikm_len, const char *salt,
                        const char *info, uint8_t out[32]) {
    crypto_sha512_hkdf(out, 32, ikm, ikm_len, (const uint8_t *)salt, strlen(salt),
                       (const uint8_t *)info, strlen(info));
}

static void client_nonce(const char *nonce8, uint8_t nonce12[12]) {
    memset(nonce12, 0, 12);
    memcpy(nonce12 + 4, nonce8, 8);
}

static void client_seal(const uint8_t key[32], const char *nonce8, const uint8_t *pt,
                        size_t len, uint8_t *ct, uint8_t tag[16]) {
    uint8_t nonce12[12];
    crypto_aead_ctx c;
    client_nonce(nonce8, nonce12);
    crypto_aead_init_ietf(&c, key, nonce12);
    crypto_aead_write(&c, ct, tag, NULL, 0, pt, len);
    crypto_wipe(&c, sizeof(c));
}

static int client_open(const uint8_t key[32], const char *nonce8, const uint8_t *ct,
                       size_t len, uint8_t *pt, const uint8_t tag[16]) {
    uint8_t nonce12[12];
    crypto_aead_ctx c;
    client_nonce(nonce8, nonce12);
    crypto_aead_init_ietf(&c, key, nonce12);
    int rc = crypto_aead_read(&c, pt, tag, NULL, 0, ct, len);
    crypto_wipe(&c, sizeof(c));
    return rc == 0;
}

/* M = H(H(N) xor H(g) || H("Pair-Setup") || salt || PAD(A) || PAD(B) || K) */
static void client_srp_proof(const uint8_t salt[SRP_SALT_BYTES],
                             const uint8_t A_pad[SRP_N_BYTES],
                             const uint8_t B_pad[SRP_N_BYTES],
                             const uint8_t K[SRP_SKEY_LEN], uint8_t M[SRP_HASH_LEN]) {
    ng_t *ng = ng_new();
    uint8_t N_pad[SRP_N_BYTES], g = 5, H_N[64], H_g[64], H_I[64], H_xor[64];
    assert(ng);
    bn_pad(ng->N, N_pad);
    ng_free(ng);
    part_t pn[] = {{N_pad, SRP_N_BYTES}}, pg[] = {{&g, 1}}, pi[] = {{"Pair-Setup", 10}};
    sha512_parts(H_N, pn, 1); sha512_parts(H_g, pg, 1); sha512_parts(H_I, pi, 1);
    for (int i = 0; i < 64; i++) H_xor[i] = H_N[i] ^ H_g[i];
    part_t pm[] = {{H_xor, 64}, {H_I, 64}, {salt, SRP_SALT_BYTES},
                   {A_pad, SRP_N_BYTES}, {B_pad, SRP_N_BYTES}, {K, SRP_SKEY_LEN}};
    sha512_parts(M, pm, 6);
}

static void unhex(const char *hex, uint8_t *out, size_t n) {
    assert(strlen(hex) == n * 2);
    for (size_t i = 0; i < n; i++) {
        unsigned int byte = 0;
        assert(sscanf(hex + 2 * i, "%2x", &byte) == 1);
        out[i] = (uint8_t)byte;
    }
}

static void test_malformed_tlv(void) {
    const uint8_t truncated[] = { TLV_STATE, 1, 1, TLV_PUBLIC_KEY, 3, 42 };
    tlv_t *t = tlv_parse(truncated, sizeof(truncated));
    assert(t == NULL);
    const uint8_t trailing[] = { TLV_STATE, 1, 1, TLV_PUBLIC_KEY };
    assert(tlv_parse(trailing, sizeof(trailing)) == NULL);
}

static void test_missing_signature(void) {
    uint8_t sk[32] = {1}, pk[32] = {0};
    pair_ctx_t *ctx = pair_ctx_create(sk, pk, NULL);
    assert(ctx);
    ctx->setup_state = 4;
    ctx->srp_has_session_key = 1;
    memset(ctx->srp_session_key, 0x31, sizeof(ctx->srp_session_key));
    uint8_t ident[] = "phone", client_key[32] = {7};
    tlv_item_t items[] = {{TLV_IDENTIFIER, ident, sizeof(ident)-1},
                          {TLV_PUBLIC_KEY, client_key, sizeof(client_key)}};
    size_t sub_len, req_len, out_len;
    uint8_t *sub = tlv_build(items, 2, &sub_len);
    uint8_t key[32], enc[272];
    assert(sub && sub_len <= 256);
    client_hkdf(ctx->srp_session_key, SRP_SKEY_LEN, "Pair-Setup-Encrypt-Salt",
                "Pair-Setup-Encrypt-Info", key);
    client_seal(key, "PS-Msg05", sub, sub_len, enc, enc + sub_len);
    uint8_t state = 5;
    tlv_item_t req[] = {{TLV_STATE, &state, 1}, {TLV_ENCRYPTED_DATA, enc, sub_len+16}};
    uint8_t *buf = tlv_build(req, 2, &req_len);
    uint8_t *response = pair_setup_handle(ctx, buf, req_len, &out_len);
    assert(response && !pair_setup_is_complete(ctx) && pair_ctx_peer_count(ctx) == 0);
    free(response); free(buf); free(sub); pair_ctx_destroy(ctx);
}

static void test_signature(int corrupt) {
    uint8_t seed[32] = {3}, secret[64], client_key[32];
    uint8_t sk[32] = {1}, pk[32] = {0};
    crypto_ed25519_key_pair(secret, client_key, seed);
    pair_ctx_t *ctx = pair_ctx_create(sk, pk, NULL);
    assert(ctx); ctx->setup_state = 4; ctx->srp_has_session_key = 1;
    memset(ctx->srp_session_key, 0x42, sizeof(ctx->srp_session_key));
    uint8_t ident[] = "phone", controllerX[32], signed_data[32+5+32], sig[64];
    client_hkdf(ctx->srp_session_key, SRP_SKEY_LEN, "Pair-Setup-Controller-Sign-Salt",
                "Pair-Setup-Controller-Sign-Info", controllerX);
    memcpy(signed_data, controllerX, 32); memcpy(signed_data+32, ident, 5);
    memcpy(signed_data+37, client_key, 32);
    crypto_ed25519_sign(sig, secret, signed_data, sizeof(signed_data));
    if (corrupt) sig[0] ^= 1;
    tlv_item_t items[] = {{TLV_IDENTIFIER, ident, 5}, {TLV_PUBLIC_KEY, client_key, 32},
                          {TLV_SIGNATURE, sig, 64}};
    size_t sub_len, req_len, out_len;
    uint8_t *sub=tlv_build(items, 3, &sub_len), key[32], enc[256];
    assert(sub && sub_len + 16 <= sizeof(enc));
    client_hkdf(ctx->srp_session_key, SRP_SKEY_LEN, "Pair-Setup-Encrypt-Salt",
                "Pair-Setup-Encrypt-Info", key);
    client_seal(key, "PS-Msg05", sub, sub_len, enc, enc + sub_len);
    uint8_t state=5;
    tlv_item_t req[] = {{TLV_STATE, &state, 1}, {TLV_ENCRYPTED_DATA, enc, sub_len+16}};
    uint8_t *buf=tlv_build(req, 2, &req_len);
    uint8_t *out=pair_setup_handle(ctx, buf, req_len, &out_len);
    assert(out && pair_setup_is_complete(ctx) == !corrupt &&
           pair_ctx_peer_count(ctx) == (size_t)!corrupt);
    free(out); free(buf); free(sub); pair_ctx_destroy(ctx);
}

/* ── Client-side helpers: drive the real handlers exactly like an iPhone. ── */

typedef struct { uint8_t seed[32], secret[64], pk[32]; } ed_identity_t;

typedef struct {
    uint8_t A[SRP_N_BYTES];
    uint8_t M[SRP_HASH_LEN];
    uint8_t K[SRP_SKEY_LEN];
    uint8_t H_AMK[SRP_HASH_LEN];
} srp_client_t;

static void make_identity(ed_identity_t *id, uint8_t seed_byte) {
    uint8_t seed[32];
    memset(seed, seed_byte, sizeof(seed));
    memcpy(id->seed, seed, sizeof(seed));
    crypto_ed25519_key_pair(id->secret, id->pk, seed); /* wipes seed copy */
}

static pair_ctx_t *make_server(ed_identity_t *server) {
    make_identity(server, 0x11);
    pair_ctx_t *ctx = pair_ctx_create(server->seed, server->pk, NULL);
    assert(ctx);
    return ctx;
}

static tlv_t *exchange(pair_ctx_t *ctx, int verify, const tlv_item_t *items, int count) {
    size_t req_len = 0, out_len = 0;
    uint8_t *req = tlv_build(items, count, &req_len);
    assert(req);
    uint8_t *out = verify ? pair_verify_handle(ctx, req, req_len, &out_len)
                          : pair_setup_handle(ctx, req, req_len, &out_len);
    free(req);
    assert(out && out_len > 0);
    tlv_t *t = tlv_parse(out, out_len);
    free(out);
    assert(t);
    return t;
}

static int is_error(const tlv_t *t) { return tlv_find(t, TLV_ERROR) != NULL; }

static tlv_t *setup_m1(pair_ctx_t *ctx) {
    uint8_t state = 1, method = 0;
    tlv_item_t req[] = {{TLV_STATE, &state, 1}, {TLV_METHOD, &method, 1}};
    tlv_t *m2 = exchange(ctx, 0, req, 2);
    const tlv_item_t *salt = tlv_find(m2, TLV_SALT), *B = tlv_find(m2, TLV_PUBLIC_KEY);
    assert(!is_error(m2) && salt && salt->len == SRP_SALT_BYTES && B &&
           B->len > 0 && B->len <= SRP_N_BYTES);
    return m2;
}

static tlv_t *setup_m3(pair_ctx_t *ctx, const uint8_t *A, size_t A_len,
                       const uint8_t M[SRP_HASH_LEN]) {
    uint8_t state = 3;
    tlv_item_t req[] = {{TLV_STATE, &state, 1},
                        {TLV_PUBLIC_KEY, (uint8_t *)A, A_len},
                        {TLV_PROOF, (uint8_t *)M, SRP_HASH_LEN}};
    return exchange(ctx, 0, req, 3);
}

/* Client SRP-6a written from the spec (independent of the server helpers):
 *   x = H(salt || H("Pair-Setup:" || pin))   salt = the raw 16 TLV bytes
 *   k = H(PAD(N) || PAD(g)),  u = H(PAD(A) || PAD(B))
 *   S = (B - k*g^x)^(a + u*x),  K = H(S),  M = client_srp_proof,
 *   H_AMK = H(PAD(A) || M || K). */
static void srp_client_compute_with(const tlv_t *m2, const char *pin,
                                    const uint8_t a_bytes[32], srp_client_t *out) {
    const tlv_item_t *salt = tlv_find(m2, TLV_SALT), *Bi = tlv_find(m2, TLV_PUBLIC_KEY);
    assert(salt && salt->len == SRP_SALT_BYTES && Bi && Bi->len <= SRP_N_BYTES);
    uint8_t inner[64], xh[64], kh[64], uh[64];
    uint8_t N_pad[SRP_N_BYTES], g_pad[SRP_N_BYTES], B_pad[SRP_N_BYTES];
    part_t pin_parts[] = {{"Pair-Setup:", 11}, {pin, strlen(pin)}};
    sha512_parts(inner, pin_parts, 2);
    part_t x_parts[] = {{salt->data, SRP_SALT_BYTES}, {inner, 64}};
    sha512_parts(xh, x_parts, 2);
    ng_t *ng = ng_new();
    assert(ng);
    bn_pad(ng->N, N_pad); bn_pad(ng->g, g_pad);
    part_t k_parts[] = {{N_pad, SRP_N_BYTES}, {g_pad, SRP_N_BYTES}};
    sha512_parts(kh, k_parts, 2);
    memset(B_pad, 0, sizeof(B_pad));
    memcpy(B_pad + (SRP_N_BYTES - Bi->len), Bi->data, Bi->len);
    BIGNUM *a = BN_bin2bn(a_bytes, 32, NULL), *B = BN_bin2bn(B_pad, SRP_N_BYTES, NULL);
    BIGNUM *x = BN_bin2bn(xh, 64, NULL), *k = BN_bin2bn(kh, 64, NULL);
    BIGNUM *A = BN_new(), *S = BN_new(), *gx = BN_new(), *kgx = BN_new();
    BIGNUM *base = BN_new(), *ux = BN_new(), *exp = BN_new();
    assert(a && B && x && k && A && S && gx && kgx && base && ux && exp);
    assert(BN_mod_exp(A, ng->g, a, ng->N, NULL));
    bn_pad(A, out->A);
    part_t u_parts[] = {{out->A, SRP_N_BYTES}, {B_pad, SRP_N_BYTES}};
    sha512_parts(uh, u_parts, 2);
    BIGNUM *u = BN_bin2bn(uh, 64, NULL);
    assert(u);
    assert(BN_mod_exp(gx, ng->g, x, ng->N, NULL) && BN_mod_mul(kgx, k, gx, ng->N, NULL));
    assert(mp_submod(B, kgx, ng->N, base) == MP_OKAY);
    assert(BN_mul(ux, u, x, NULL) && mp_add(a, ux, exp) == MP_OKAY);
    assert(BN_mod_exp(S, base, exp, ng->N, NULL));
    int S_len = BN_num_bytes(S);
    uint8_t S_bytes[SRP_N_BYTES];
    assert(S_len > 0 && S_len <= SRP_N_BYTES && BN_bn2bin(S, S_bytes) == S_len);
    part_t s_parts[] = {{S_bytes, (size_t)S_len}};
    sha512_parts(out->K, s_parts, 1);
    client_srp_proof(salt->data, out->A, B_pad, out->K, out->M);
    part_t amk_parts[] = {{out->A, SRP_N_BYTES}, {out->M, SRP_HASH_LEN}, {out->K, SRP_SKEY_LEN}};
    sha512_parts(out->H_AMK, amk_parts, 3);
    BN_free(a); BN_free(B); BN_free(A); BN_free(S); BN_free(gx);
    BN_free(kgx); BN_free(base); BN_free(ux); BN_free(exp); BN_free(x);
    BN_free(k); BN_free(u); ng_free(ng);
    crypto_wipe(S_bytes, sizeof(S_bytes));
}

static void srp_client_compute(const tlv_t *m2, const char *pin, srp_client_t *out) {
    uint8_t a_bytes[32];
    assert(SecRandomCopyBytes(kSecRandomDefault, sizeof(a_bytes), a_bytes) == errSecSuccess);
    srp_client_compute_with(m2, pin, a_bytes, out);
    crypto_wipe(a_bytes, sizeof(a_bytes));
}

static tlv_t *setup_m5(pair_ctx_t *ctx, const uint8_t K[SRP_SKEY_LEN], const char *ident,
                       const ed_identity_t *client, int corrupt) {
    size_t ident_len = strlen(ident), sub_len = 0;
    assert(ident_len > 0 && ident_len <= MAX_PEER_IDENTIFIER_LEN);
    uint8_t controllerX[32], signed_data[32 + MAX_PEER_IDENTIFIER_LEN + 32], sig[64];
    client_hkdf(K, SRP_SKEY_LEN, "Pair-Setup-Controller-Sign-Salt",
                "Pair-Setup-Controller-Sign-Info", controllerX);
    memcpy(signed_data, controllerX, 32); memcpy(signed_data + 32, ident, ident_len);
    memcpy(signed_data + 32 + ident_len, client->pk, 32);
    crypto_ed25519_sign(sig, client->secret, signed_data, 64 + ident_len);
    if (corrupt) sig[0] ^= 1;
    tlv_item_t items[] = {{TLV_IDENTIFIER, (uint8_t *)ident, ident_len},
                          {TLV_PUBLIC_KEY, (uint8_t *)client->pk, 32},
                          {TLV_SIGNATURE, sig, 64}};
    uint8_t *sub = tlv_build(items, 3, &sub_len), key[32];
    uint8_t *enc = malloc(sub_len + 16);
    assert(sub && enc);
    client_hkdf(K, SRP_SKEY_LEN, "Pair-Setup-Encrypt-Salt", "Pair-Setup-Encrypt-Info", key);
    client_seal(key, "PS-Msg05", sub, sub_len, enc, enc + sub_len);
    uint8_t state = 5;
    tlv_item_t req[] = {{TLV_STATE, &state, 1}, {TLV_ENCRYPTED_DATA, enc, sub_len + 16}};
    tlv_t *m6 = exchange(ctx, 0, req, 2);
    free(enc); free(sub);
    return m6;
}

static void check_m6(const tlv_t *m6, const uint8_t K[SRP_SKEY_LEN],
                     const uint8_t server_pk[32]) {
    const tlv_item_t *enc = tlv_find(m6, TLV_ENCRYPTED_DATA);
    assert(!is_error(m6) && enc && enc->len > 16);
    uint8_t key[32], accessoryX[32], msg[32 + MAX_PEER_IDENTIFIER_LEN + 32];
    client_hkdf(K, SRP_SKEY_LEN, "Pair-Setup-Encrypt-Salt", "Pair-Setup-Encrypt-Info", key);
    int ct_len = (int)enc->len - 16;
    uint8_t *pt = malloc((size_t)ct_len);
    assert(pt && client_open(key, "PS-Msg06", enc->data, (size_t)ct_len,
                             pt, enc->data + ct_len));
    tlv_t *sub = tlv_parse(pt, (size_t)ct_len);
    free(pt);
    assert(sub);
    const tlv_item_t *ident = tlv_find(sub, TLV_IDENTIFIER);
    const tlv_item_t *pk = tlv_find(sub, TLV_PUBLIC_KEY), *sig = tlv_find(sub, TLV_SIGNATURE);
    assert(ident && ident->len <= MAX_PEER_IDENTIFIER_LEN && pk && pk->len == 32 &&
           !memcmp(pk->data, server_pk, 32) && sig && sig->len == 64);
    client_hkdf(K, SRP_SKEY_LEN, "Pair-Setup-Accessory-Sign-Salt",
                "Pair-Setup-Accessory-Sign-Info", accessoryX);
    memcpy(msg, accessoryX, 32); memcpy(msg + 32, ident->data, ident->len);
    memcpy(msg + 32 + ident->len, server_pk, 32);
    assert(crypto_ed25519_check(sig->data, server_pk, msg, 64 + ident->len) == 0);
    tlv_free(sub);
}

/* Full SRP M1→M4 as an honest client with `pin`. Returns 1 when M4 is accepted. */
static int run_setup_m1_m3(pair_ctx_t *ctx, const char *pin, srp_client_t *client) {
    tlv_t *m2 = setup_m1(ctx);
    srp_client_compute(m2, pin, client);
    tlv_free(m2);
    tlv_t *m4 = setup_m3(ctx, client->A, sizeof(client->A), client->M);
    int ok = !is_error(m4);
    if (ok) {
        const tlv_item_t *proof = tlv_find(m4, TLV_PROOF);
        assert(proof && proof->len == SRP_HASH_LEN &&
               !memcmp(proof->data, client->H_AMK, SRP_HASH_LEN));
    } else {
        assert(!tlv_find(m4, TLV_PROOF));
    }
    tlv_free(m4);
    return ok;
}

/* Pair-verify M1→M4 as a controller. Returns 1 when M4 succeeded. */
static int run_verify(pair_ctx_t *ctx, const uint8_t server_pk[32], const char *ident,
                      const ed_identity_t *client, int corrupt, int replay) {
    uint8_t csk[32], cpk[32], shared[32], key[32], spk[32], rk[32], wk[32];
    uint8_t msg[32 + MAX_PEER_IDENTIFIER_LEN + 32], sig[64], state = 1;
    size_t ident_len = strlen(ident), sub_len = 0;
    assert(ident_len > 0 && ident_len <= MAX_PEER_IDENTIFIER_LEN);
    assert(SecRandomCopyBytes(kSecRandomDefault, sizeof(csk), csk) == errSecSuccess);
    crypto_x25519_public_key(cpk, csk);
    tlv_item_t m1[] = {{TLV_STATE, &state, 1}, {TLV_PUBLIC_KEY, cpk, 32}};
    tlv_t *m2 = exchange(ctx, 1, m1, 2);
    const tlv_item_t *spk_item = tlv_find(m2, TLV_PUBLIC_KEY);
    const tlv_item_t *enc = tlv_find(m2, TLV_ENCRYPTED_DATA);
    assert(!is_error(m2) && spk_item && spk_item->len == 32 && enc && enc->len > 16);
    memcpy(spk, spk_item->data, 32);
    crypto_x25519(shared, csk, spk);
    client_hkdf(shared, 32, "Pair-Verify-Encrypt-Salt", "Pair-Verify-Encrypt-Info", key);
    int ct_len = (int)enc->len - 16;
    uint8_t *pt = malloc((size_t)ct_len);
    assert(pt && client_open(key, "PV-Msg02", enc->data, (size_t)ct_len,
                             pt, enc->data + ct_len));
    tlv_free(m2);
    tlv_t *sub = tlv_parse(pt, (size_t)ct_len);
    free(pt);
    assert(sub);
    const tlv_item_t *sident = tlv_find(sub, TLV_IDENTIFIER), *ssig = tlv_find(sub, TLV_SIGNATURE);
    assert(sident && sident->len <= MAX_PEER_IDENTIFIER_LEN && ssig && ssig->len == 64);
    memcpy(msg, spk, 32); memcpy(msg + 32, sident->data, sident->len);
    memcpy(msg + 32 + sident->len, cpk, 32);
    assert(crypto_ed25519_check(ssig->data, server_pk, msg, 64 + sident->len) == 0);
    tlv_free(sub);

    memcpy(msg, cpk, 32); memcpy(msg + 32, ident, ident_len);
    memcpy(msg + 32 + ident_len, spk, 32);
    crypto_ed25519_sign(sig, client->secret, msg, 64 + ident_len);
    if (corrupt) sig[0] ^= 1;
    tlv_item_t sub_items[] = {{TLV_IDENTIFIER, (uint8_t *)ident, ident_len},
                              {TLV_SIGNATURE, sig, 64}};
    uint8_t *sub_buf = tlv_build(sub_items, 2, &sub_len);
    uint8_t *m3_enc = malloc(sub_len + 16);
    assert(sub_buf && m3_enc);
    client_seal(key, "PV-Msg03", sub_buf, sub_len, m3_enc, m3_enc + sub_len);
    state = 3;
    tlv_item_t m3[] = {{TLV_STATE, &state, 1}, {TLV_ENCRYPTED_DATA, m3_enc, sub_len + 16}};
    tlv_t *m4 = exchange(ctx, 1, m3, 2);
    int ok = !is_error(m4);
    assert(ok == pair_verify_is_complete(ctx));
    assert((pair_derive_control_keys(ctx, rk, wk) == 0) == ok);
    tlv_free(m4);
    if (replay) {
        tlv_t *again = exchange(ctx, 1, m3, 2);
        assert(is_error(again) && !pair_verify_is_complete(ctx) &&
               pair_derive_control_keys(ctx, rk, wk) != 0);
        tlv_free(again);
    }
    free(m3_enc); free(sub_buf);
    crypto_wipe(csk, sizeof(csk)); crypto_wipe(shared, sizeof(shared));
    return ok;
}

/* Out-of-order messages must be rejected by the state gate itself, even when
 * the message content would otherwise be acceptable. */
static void test_stale_state(void) {
    ed_identity_t server, client;
    make_identity(&client, 0x22);
    pair_ctx_t *ctx = make_server(&server);
    uint8_t K[SRP_SKEY_LEN];
    memset(K, 0x42, sizeof(K));
    /* M5 with a leftover session key but no M4 in this attempt. */
    ctx->srp_has_session_key = 1;
    memcpy(ctx->srp_session_key, K, sizeof(K));
    tlv_t *m6 = setup_m5(ctx, K, "phone", &client, 0);
    assert(is_error(m6) && !pair_setup_is_complete(ctx) && pair_ctx_peer_count(ctx) == 0);
    tlv_free(m6);
    /* M3 before M1. */
    uint8_t A[SRP_N_BYTES], M[SRP_HASH_LEN];
    memset(A, 0x05, sizeof(A)); memset(M, 0x06, sizeof(M));
    tlv_t *m4 = setup_m3(ctx, A, sizeof(A), M);
    assert(is_error(m4) && !tlv_find(m4, TLV_PROOF));
    tlv_free(m4);
    /* pair-verify M3 before M1. */
    uint8_t state = 3, enc[48] = {0};
    tlv_item_t req[] = {{TLV_STATE, &state, 1}, {TLV_ENCRYPTED_DATA, enc, sizeof(enc)}};
    tlv_t *v4 = exchange(ctx, 1, req, 2);
    assert(is_error(v4) && !pair_verify_is_complete(ctx));
    tlv_free(v4);
    pair_ctx_destroy(ctx);
}

static void test_full_flow(void) {
    ed_identity_t server, client;
    make_identity(&client, 0x22);
    pair_ctx_t *ctx = make_server(&server);
    srp_client_t srp;
    assert(run_setup_m1_m3(ctx, SRP_DEFAULT_PIN, &srp));
    assert(!pair_setup_is_complete(ctx));
    tlv_t *m6 = setup_m5(ctx, srp.K, "phone", &client, 0);
    check_m6(m6, srp.K, server.pk);
    tlv_free(m6);
    assert(pair_setup_is_complete(ctx) && pair_ctx_peer_count(ctx) == 1);
    assert(run_verify(ctx, server.pk, "phone", &client, 0, 1));
    pair_ctx_destroy(ctx);
}

/* Known-answer vector, computed outside this code base (Python hashlib/hmac)
 * from the spec formulas above. salt[0] == 0x00 pins the leading-zero salt
 * case that random salts only hit 1 time in 256. */
static void test_known_answer(void) {
    static const char *K_hex =
        "0f1e8437bdb29adc0a62c53f9aa86a8b3d39419f3fdeca41b9dbf1374de9f349"
        "99b972ae3df42d2fc4c08299850407252c607798978222c0685cc73ebc9a93bc";
    static const char *M_hex =
        "3863d925a1231474f0fbc5492f62da3b1676dc1fd5e37baa8c924f3d20da69fc"
        "40315ec6cd0deacfb99276c56ac2b79e43947d7e6bbd5b0b9bee056f3c9d313a";
    static const char *H_AMK_hex =
        "b97db3e6ae39ddcc26bd0f9d3c715ee6b8d16de65af2733dae51e0b9d25592b0"
        "7813d24d8cbcd5c397a11231670a98d45942c3518dd04ea75b629072e0c21f65";
    static const char *B_prefix_hex = "3ad8b8e0a6006eae9b5557af4fa6f0c6";
    static const char *setup_key_hex =
        "c2ff233dcae214eb81d83badb3280adeb204bc3d45a509f198096700b021c451";
    static const char *control_write_hex =
        "ea07c4ee5a74fea848e8c5fd92dad047f8e085713a1f410096e6fa019afc58ae";
    static const char *control_read_hex =
        "82b541050f1c1911a415d01c0607698f165bca4734e333469cb4b3506c0860db";
    uint8_t salt[SRP_SALT_BYTES], b[32], a[32], shared[32];
    uint8_t K[SRP_SKEY_LEN], M[SRP_HASH_LEN], H_AMK[SRP_HASH_LEN], B_prefix[16];
    uint8_t setup_key[32], control_write[32], control_read[32], key[32], rk[32], wk[32];
    for (int i = 0; i < 16; i++) salt[i] = (uint8_t)i;
    for (int i = 0; i < 32; i++) {
        b[i] = (uint8_t)(0x40 + i); a[i] = (uint8_t)(0x60 + i); shared[i] = (uint8_t)(0x80 + i);
    }
    unhex(K_hex, K, sizeof(K)); unhex(M_hex, M, sizeof(M));
    unhex(H_AMK_hex, H_AMK, sizeof(H_AMK)); unhex(B_prefix_hex, B_prefix, sizeof(B_prefix));
    unhex(setup_key_hex, setup_key, 32);
    unhex(control_write_hex, control_write, 32); unhex(control_read_hex, control_read, 32);

    /* The client helpers themselves must reproduce the external HKDF vectors. */
    client_hkdf(K, SRP_SKEY_LEN, "Pair-Setup-Encrypt-Salt", "Pair-Setup-Encrypt-Info", key);
    assert(!memcmp(key, setup_key, 32));

    ed_identity_t server, client;
    make_identity(&client, 0x22);
    pair_ctx_t *ctx = make_server(&server);
    /* handle_setup_m1 draws the salt first, then b. */
    test_rng_queue[0] = (rng_script_t){salt, sizeof(salt)};
    test_rng_queue[1] = (rng_script_t){b, sizeof(b)};
    test_rng_count = 2;
    tlv_t *m2 = setup_m1(ctx);
    assert(test_rng_count == 0);
    const tlv_item_t *salt_item = tlv_find(m2, TLV_SALT), *B_item = tlv_find(m2, TLV_PUBLIC_KEY);
    assert(!memcmp(salt_item->data, salt, SRP_SALT_BYTES) && B_item->len == SRP_N_BYTES &&
           !memcmp(B_item->data, B_prefix, sizeof(B_prefix)));
    srp_client_t srp;
    srp_client_compute_with(m2, SRP_DEFAULT_PIN, a, &srp);
    tlv_free(m2);
    assert(!memcmp(srp.K, K, SRP_SKEY_LEN) && !memcmp(srp.M, M, SRP_HASH_LEN) &&
           !memcmp(srp.H_AMK, H_AMK, SRP_HASH_LEN));

    tlv_t *m4 = setup_m3(ctx, srp.A, sizeof(srp.A), M);
    const tlv_item_t *proof = tlv_find(m4, TLV_PROOF);
    assert(!is_error(m4) && proof && proof->len == SRP_HASH_LEN &&
           !memcmp(proof->data, H_AMK, SRP_HASH_LEN));
    tlv_free(m4);
    assert(ctx->srp_has_session_key && !memcmp(ctx->srp_session_key, K, SRP_SKEY_LEN));
    tlv_t *m6 = setup_m5(ctx, K, "phone", &client, 0);
    check_m6(m6, K, server.pk);
    tlv_free(m6);
    assert(pair_setup_is_complete(ctx) && pair_ctx_peer_count(ctx) == 1);

    /* Control-* keys from a fixed pair-verify shared secret (iPhone-perspective
     * labels: the receiver reads with Control-Write, writes with Control-Read). */
    memcpy(ctx->verify_shared, shared, sizeof(shared));
    ctx->verify_state = 4;
    assert(pair_derive_control_keys(ctx, rk, wk) == 0);
    assert(!memcmp(rk, control_write, 32) && !memcmp(wk, control_read, 32));
    pair_ctx_destroy(ctx);
}

/* SRP-6a safety check: A ≡ 0 (mod N) must never reach session-key derivation. */
static void test_bad_a(void) {
    ed_identity_t server;
    pair_ctx_t *ctx = make_server(&server);
    ng_t *ng = ng_new();
    BIGNUM *two_n = BN_new();
    assert(ng && two_n && mp_add(ng->N, ng->N, two_n) == MP_OKAY);
    uint8_t M[SRP_HASH_LEN];
    memset(M, 0x07, sizeof(M));
    for (int which = 0; which < 3; which++) {
        uint8_t A[SRP_N_BYTES + 1] = {0};
        size_t A_len = SRP_N_BYTES;
        if (which == 1) BN_bn2bin(ng->N, A);
        if (which == 2) { A_len = (size_t)BN_num_bytes(two_n); BN_bn2bin(two_n, A); }
        tlv_t *m2 = setup_m1(ctx);
        if (which < 2) {
            /* Attacker knows S = 0 without the PIN; forge the matching proof.
             * (2N exceeds len(N), so it keeps a junk proof.) */
            const tlv_item_t *Bi = tlv_find(m2, TLV_PUBLIC_KEY);
            uint8_t K[SRP_SKEY_LEN], B_pad[SRP_N_BYTES] = {0};
            memcpy(B_pad + (SRP_N_BYTES - Bi->len), Bi->data, Bi->len);
            part_t empty[] = {{"", 0}};  /* K = H(S) with S = 0 (minimal encoding) */
            sha512_parts(K, empty, 1);
            client_srp_proof(tlv_find(m2, TLV_SALT)->data, A, B_pad, K, M);
        }
        tlv_free(m2);
        tlv_t *m4 = setup_m3(ctx, A, A_len, M);
        assert(is_error(m4) && !tlv_find(m4, TLV_PROOF) && !ctx->srp_has_session_key);
        tlv_free(m4);
        tlv_t *m6 = setup_m5(ctx, ctx->srp_session_key, "phone", &server, 0);
        assert(is_error(m6) && !pair_setup_is_complete(ctx) && pair_ctx_peer_count(ctx) == 0);
        tlv_free(m6);
    }
    BN_free(two_n); ng_free(ng);
    pair_ctx_destroy(ctx);
}

static void test_wrong_pin(void) {
    ed_identity_t server, client;
    make_identity(&client, 0x22);
    pair_ctx_t *ctx = make_server(&server);
    srp_client_t srp;
    assert(!run_setup_m1_m3(ctx, "0000", &srp));
    assert(!ctx->srp_has_session_key);
    tlv_t *m6 = setup_m5(ctx, srp.K, "phone", &client, 0);
    assert(is_error(m6) && !pair_setup_is_complete(ctx) && pair_ctx_peer_count(ctx) == 0);
    tlv_free(m6);
    pair_ctx_destroy(ctx);
}

static void test_m3_replay(void) {
    ed_identity_t server, client;
    make_identity(&client, 0x22);
    pair_ctx_t *ctx = make_server(&server);
    srp_client_t srp;
    assert(run_setup_m1_m3(ctx, SRP_DEFAULT_PIN, &srp));
    /* Same M3 again inside the same attempt. */
    tlv_t *m4 = setup_m3(ctx, srp.A, sizeof(srp.A), srp.M);
    assert(is_error(m4) && !tlv_find(m4, TLV_PROOF));
    tlv_free(m4);
    tlv_t *m6 = setup_m5(ctx, srp.K, "phone", &client, 0);
    check_m6(m6, srp.K, server.pk);
    tlv_free(m6);
    /* After completion. */
    m4 = setup_m3(ctx, srp.A, sizeof(srp.A), srp.M);
    assert(is_error(m4) && !pair_setup_is_complete(ctx));
    tlv_free(m4);
    /* Recorded M3 against a fresh M1 (new salt/B) must not authenticate. */
    tlv_free(setup_m1(ctx));
    m4 = setup_m3(ctx, srp.A, sizeof(srp.A), srp.M);
    assert(is_error(m4) && !ctx->srp_has_session_key);
    tlv_free(m4);
    m6 = setup_m5(ctx, srp.K, "phone", &client, 0);
    assert(is_error(m6) && !pair_setup_is_complete(ctx) && pair_ctx_peer_count(ctx) == 1);
    tlv_free(m6);
    pair_ctx_destroy(ctx);
}

static void test_verify_unpaired(void) {
    ed_identity_t server, client, stranger;
    make_identity(&client, 0x22);
    make_identity(&stranger, 0x33);
    pair_ctx_t *ctx = make_server(&server);
    assert(!run_verify(ctx, server.pk, "phone", &client, 0, 0));
    assert(pair_ctx_add_peer(ctx, (const uint8_t *)"phone", 5, client.pk) == 0);
    assert(!run_verify(ctx, server.pk, "stranger", &stranger, 0, 0));
    /* Registered identifier, but signed by somebody else's key. */
    assert(!run_verify(ctx, server.pk, "phone", &stranger, 0, 0));
    assert(run_verify(ctx, server.pk, "phone", &client, 0, 0));
    pair_ctx_destroy(ctx);
}

static void test_verify_corrupt(void) {
    ed_identity_t server, client;
    make_identity(&client, 0x22);
    pair_ctx_t *ctx = make_server(&server);
    assert(pair_ctx_add_peer(ctx, (const uint8_t *)"phone", 5, client.pk) == 0);
    assert(!run_verify(ctx, server.pk, "phone", &client, 1, 0));
    pair_ctx_destroy(ctx);
}

int main(int argc, char **argv) {
    assert(argc == 2);
    if (!strcmp(argv[1], "tlv")) test_malformed_tlv();
    else if (!strcmp(argv[1], "signature")) test_missing_signature();
    else if (!strcmp(argv[1], "state")) test_stale_state();
    else if (!strcmp(argv[1], "valid")) test_signature(0);
    else if (!strcmp(argv[1], "corrupt")) test_signature(1);
    /* "flow" also runs the known-answer vector so the existing runner covers it. */
    else if (!strcmp(argv[1], "flow")) { test_full_flow(); test_known_answer(); }
    else if (!strcmp(argv[1], "kat")) test_known_answer();
    else if (!strcmp(argv[1], "bad_a")) test_bad_a();
    else if (!strcmp(argv[1], "wrong_pin")) test_wrong_pin();
    else if (!strcmp(argv[1], "m3_replay")) test_m3_replay();
    else if (!strcmp(argv[1], "verify_unpaired")) test_verify_unpaired();
    else if (!strcmp(argv[1], "verify_corrupt")) test_verify_corrupt();
    else return 2;
    return 0;
}
