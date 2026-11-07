#include <stdarg.h>
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include "../source/carplay_pair.c"

int showcase_service_log_printf(const char *format, ...) { (void)format; return 0; }

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
    uint8_t key[32], ciphertext[256], tag[16], enc[272];
    derive_pair_setup_encrypt_key(ctx->srp_session_key, SRP_SKEY_LEN, key);
    assert(chacha_encrypt(key, (const unsigned char *)"PS-Msg05", sub,
                          (int)sub_len, ciphertext, tag) == (int)sub_len);
    memcpy(enc, ciphertext, sub_len); memcpy(enc + sub_len, tag, 16);
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
    const char *salt = "Pair-Setup-Controller-Sign-Salt";
    const char *info = "Pair-Setup-Controller-Sign-Info";
    hkdf_sha512(ctx->srp_session_key, SRP_SKEY_LEN, (const uint8_t *)salt,
                (int)strlen(salt), (const uint8_t *)info, (int)strlen(info), controllerX, 32);
    memcpy(signed_data, controllerX, 32); memcpy(signed_data+32, ident, 5);
    memcpy(signed_data+37, client_key, 32);
    crypto_ed25519_sign(sig, secret, signed_data, sizeof(signed_data));
    if (corrupt) sig[0] ^= 1;
    tlv_item_t items[] = {{TLV_IDENTIFIER, ident, 5}, {TLV_PUBLIC_KEY, client_key, 32},
                          {TLV_SIGNATURE, sig, 64}};
    size_t sub_len, req_len, out_len;
    uint8_t *sub=tlv_build(items, 3, &sub_len), key[32], enc[256];
    derive_pair_setup_encrypt_key(ctx->srp_session_key, SRP_SKEY_LEN, key);
    assert(chacha_encrypt(key, (const uint8_t *)"PS-Msg05", sub, (int)sub_len,
                          enc, enc+sub_len) == (int)sub_len);
    uint8_t state=5;
    tlv_item_t req[] = {{TLV_STATE, &state, 1}, {TLV_ENCRYPTED_DATA, enc, sub_len+16}};
    uint8_t *buf=tlv_build(req, 2, &req_len);
    uint8_t *out=pair_setup_handle(ctx, buf, req_len, &out_len);
    assert(out && pair_setup_is_complete(ctx) == !corrupt &&
           pair_ctx_peer_count(ctx) == (size_t)!corrupt);
    free(out); free(buf); free(sub); pair_ctx_destroy(ctx);
}

static void test_stale_state(void) {
    uint8_t sk[32] = {1}, pk[32] = {0};
    pair_ctx_t *ctx = pair_ctx_create(sk, pk, NULL);
    assert(ctx);
    ctx->verify_state = 4;
    const uint8_t bad[] = { TLV_STATE, 1, 1, TLV_PUBLIC_KEY, 1, 42 };
    size_t out_len = 0;
    uint8_t *out = pair_verify_handle(ctx, bad, sizeof(bad), &out_len);
    assert(out && !pair_verify_is_complete(ctx));
    free(out); pair_ctx_destroy(ctx);
}

int main(int argc, char **argv) {
    assert(argc == 2);
    if (!strcmp(argv[1], "tlv")) test_malformed_tlv();
    else if (!strcmp(argv[1], "signature")) test_missing_signature();
    else if (!strcmp(argv[1], "state")) test_stale_state();
    else if (!strcmp(argv[1], "valid")) test_signature(0);
    else if (!strcmp(argv[1], "corrupt")) test_signature(1);
    else return 2;
    return 0;
}
