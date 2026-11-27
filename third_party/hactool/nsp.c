#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include "types.h"
#include "utils.h"
#include "pfs0.h"
#include "nca.h"
#include "nsp.h"
#include "extkeys.h"

/* Repackers sometimes wrap the title key with a different titlekek generation
 * than the one stamped in the ticket (the console tolerates it because the
 * content is encrypted with the header's generation). Keep the ciphertext so a
 * failing NCA can be retried with the header's generation instead. */
typedef struct {
    unsigned char rights_id[0x10];
    unsigned char cipher[0x10];
    unsigned char gen;
    int used;
} ticket_record_t;

static ticket_record_t g_tickets[8];
static unsigned int g_ticket_count = 0;

static ticket_record_t *ticket_record_for(const unsigned char *rights_id) {
    for (unsigned int i = 0; i < g_ticket_count; i++) {
        if (g_tickets[i].used && memcmp(g_tickets[i].rights_id, rights_id, 0x10) == 0) {
            return &g_tickets[i];
        }
    }
    return NULL;
}

static int derive_titlekey_with_gen(hactool_ctx_t *tool_ctx, unsigned char gen, const unsigned char *cipher, unsigned char *out) {
    if (gen > 0x16) return 0;
    aes_ctx_t *aes = new_aes_ctx(tool_ctx->settings.keyset.titlekeks[gen], 16, AES_MODE_ECB);
    aes_decrypt(aes, out, cipher, 0x10);
    free_aes_ctx(aes);
    return 1;
}

static int ends_with_nca(const char *name, size_t len) {
    return len >= 4 && strcasecmp(name + len - 4, ".nca") == 0;
}

static int ends_with_tik(const char *name, size_t len) {
    return len >= 4 && strcasecmp(name + len - 4, ".tik") == 0;
}

/* A retail NSP carries the title key encrypted inside its ticket. DBI derives
 * that key with the console's titlekeks and can therefore hash-verify content
 * with nothing but prod.keys + the package itself. Registering the ticket key
 * gives hactool the same footing, so "-t nsp -y" can verify hashes without the
 * user also having to supply a matching title.keys. */
static int register_ticket_key(hactool_ctx_t *tool_ctx, FILE *file, uint64_t offset, uint64_t size) {
    unsigned char buf[0x2C0];
    uint32_t sig_type;
    size_t sig_size, block_ofs, key_ofs, rights_ofs;

    if (size < sizeof(buf)) return 0;
    fseeko64(file, offset, SEEK_SET);
    if (fread(buf, 1, sizeof(buf), file) != sizeof(buf)) return 0;

    sig_type = (uint32_t)buf[0] | ((uint32_t)buf[1] << 8) | ((uint32_t)buf[2] << 16) | ((uint32_t)buf[3] << 24);
    switch (sig_type) {
        case 0x10000: /* RSA-4096 SHA-1 */
        case 0x10003: /* RSA-4096 SHA-256 */
            sig_size = 0x200;
            break;
        case 0x10001: /* RSA-2048 SHA-1 */
        case 0x10004: /* RSA-2048 SHA-256 */
            sig_size = 0x100;
            break;
        case 0x10002: /* ECDSA SHA-1 */
        case 0x10005: /* ECDSA SHA-256 */
            sig_size = 0x3C;
            break;
        default:
            return 0;
    }

    block_ofs = 4 + sig_size;
    block_ofs += 0x40 - (block_ofs % 0x40);
    key_ofs = block_ofs + 0x40;      /* title key block follows the issuer */
    rights_ofs = key_ofs + 0x120;    /* ...then 0x100 key block, 0x20 header */
    if (rights_ofs + 0x10 > sizeof(buf)) return 0;
    if (settings_has_titlekey(&tool_ctx->settings, buf + rights_ofs)) return 1;

    /* The ticket wraps the title key with titlekek[ticket keygen]. The NCA's
     * own key revision is often different (0x0 in the ticket, 0x6 in the NCA
     * header on retail RE1), so letting hactool re-decrypt with the NCA's
     * revision produced garbage keys and every hash read as corrupt. Decrypt
     * here, with the ticket's revision, and hand over the plaintext key. */
    {
        unsigned char key_type = buf[key_ofs + 0x101];
        /* Key revision lives at 0x285 in a 0x180-key ticket (the byte before
         * the ticket ID); reading 0x286 lands on padding and yields 0x00. */
        unsigned char keygen = buf[key_ofs + 0x105];
        unsigned char dec[0x10];
        aes_ctx_t *aes;

        if (key_type != 0) {
            /* Personalized ticket: wrapped with a console-unique key we do not
             * have. Leave unregistered so the NCA check reports "unverified"
             * rather than "corrupt". */
            printf("NSP_TICKET_PERSONALIZED: skipped one console-personalized ticket\n");
            return -1;
        }
        aes = new_aes_ctx(tool_ctx->settings.keyset.titlekeks[keygen], 16, AES_MODE_ECB);
        aes_decrypt(aes, dec, buf + key_ofs, 0x10);
        free_aes_ctx(aes);
        settings_add_decrypted_titlekey(&tool_ctx->settings, buf + rights_ofs, dec);

        if (g_ticket_count < sizeof(g_tickets)/sizeof(g_tickets[0])) {
            ticket_record_t *rec = &g_tickets[g_ticket_count++];
            memcpy(rec->rights_id, buf + rights_ofs, 0x10);
            memcpy(rec->cipher, buf + key_ofs, 0x10);
            rec->gen = keygen;
            rec->used = 1;
        }
    }
    return 1;
}

void nsp_process(nsp_ctx_t *ctx) {
    pfs0_header_t header;
    pfs0_file_entry_t *entries = NULL;
    char *string_table = NULL;
    uint64_t entries_size = 0;
    uint64_t data_start = 0;
    uint64_t file_size = 0;
    unsigned int processed = 0, skipped = 0;

    fseeko64(ctx->file, 0, SEEK_END);
    file_size = (uint64_t)ftello(ctx->file);

    fseeko64(ctx->file, 0, SEEK_SET);
    if (fread(&header, 1, sizeof(header), ctx->file) != sizeof(header)) {
        fprintf(stderr, "Failed to read NSP header!\n");
        printf("NSP_RESULT: 0 nca(s), 0 skipped (header unreadable)\n");
        return;
    }
    if (header.magic != MAGIC_PFS0) {
        printf("Error: NSP is corrupt (not a PFS0 container)!\n");
        printf("NSP_RESULT: 0 nca(s), 0 skipped (not PFS0)\n");
        return;
    }
    if (header.num_files == 0 || header.num_files > 0x1000) {
        fprintf(stderr, "NSP declares an impossible file count (%u)!\n", header.num_files);
        printf("NSP_RESULT: 0 nca(s), 0 skipped (bad file count)\n");
        return;
    }

    entries_size = (uint64_t)header.num_files * sizeof(pfs0_file_entry_t);
    entries = malloc(entries_size);
    string_table = malloc((size_t)header.string_table_size + 1);
    if (entries == NULL || string_table == NULL) {
        fprintf(stderr, "Failed to allocate NSP tables!\n");
        free(entries);
        free(string_table);
        printf("NSP_RESULT: 0 nca(s), 0 skipped (allocation failed)\n");
        return;
    }

    if (fread(entries, 1, entries_size, ctx->file) != entries_size ||
        (header.string_table_size && fread(string_table, 1, header.string_table_size, ctx->file) != header.string_table_size)) {
        fprintf(stderr, "Failed to read NSP tables!\n");
        free(entries);
        free(string_table);
        printf("NSP_RESULT: 0 nca(s), 0 skipped (tables unreadable)\n");
        return;
    }
    string_table[header.string_table_size] = 0;

    data_start = sizeof(pfs0_header_t) + entries_size + header.string_table_size;
    printf("NSP: %u file(s), payload at 0x%012"PRIx64"\n", header.num_files, data_start);

    /* Register ticket title keys before any NCA is opened: section decryption
     * looks them up by rights ID, and without them every hash would read as
     * corrupt. */
    unsigned int tickets = 0, personalized = 0;
    for (unsigned int i = 0; i < header.num_files; i++) {
        uint64_t entry_start, entry_size;
        size_t name_len;
        char *name;

        if (entries[i].string_table_offset >= header.string_table_size) continue;
        name = string_table + entries[i].string_table_offset;
        name_len = strlen(name);
        if (!ends_with_tik(name, name_len)) continue;

        entry_start = data_start + entries[i].offset;
        entry_size = entries[i].size;
        if (entry_start > file_size || entry_size > file_size - entry_start) continue;
        int rc = register_ticket_key(ctx->tool_ctx, ctx->file, entry_start, entry_size);
        if (rc > 0) tickets++;
        else if (rc < 0) personalized++;
    }
    printf("NSP_TICKETS: %u key(s) registered from tickets\n", tickets);
    /* A package whose keys we could not derive must never be reported as
     * "content corrupt": hash failures there only mean "could not decrypt". */
    printf("NSP_KEYSTATE: registered=%u personalized=%u\n", tickets, personalized);
    fflush(stdout);

    for (unsigned int i = 0; i < header.num_files; i++) {
        uint64_t entry_start = data_start + entries[i].offset;
        uint64_t entry_size = entries[i].size;
        size_t name_len;
        char *name;

        if (entries[i].string_table_offset >= header.string_table_size) {
            skipped++;
            continue;
        }
        name = string_table + entries[i].string_table_offset;
        name_len = strlen(name);
        if (!ends_with_nca(name, name_len)) {
            continue;
        }
        if (entry_start > file_size || entry_size > file_size - entry_start) {
            /* A truncated entry is exactly what the structural pass calls
             * blocked; say so instead of reading past the end. */
            printf("\nNSP_NCA_BEGIN: %s\n", name);
            printf("NSP_NCA_ERROR: entry runs past the end of the file\n");
            printf("\nNSP_NCA_END: %s\n", name);
            fflush(stdout);
            skipped++;
            continue;
        }

        nca_ctx_t nca;
        nca_init(&nca);
        nca.file = ctx->file;
        nca.tool_ctx = ctx->tool_ctx;
        nca.is_cli_target = true;
        nca.base_offset = entry_start;
        nca.file_size = (size_t)entry_size;

        printf("\nNSP_NCA_BEGIN: %s\n", name);
        fflush(stdout);
        nca_process(&nca);
        fflush(stdout);

        /* If the content will not decrypt with the ticket's generation but the
         * NCA header promises a different one, try that before calling the
         * package corrupt. NSZ/repacked packages re-encrypt with the key
         * generation stored in the NCA header, so a large NCA is exactly where
         * a stale ticket generation shows up first, and a wrong generation
         * would otherwise read as "content corrupt". The retry only re-derives
         * the title key and re-verifies in memory; it writes no large file, so
         * there is deliberately no size cap (an 11 GB Overcooked main NCA was
         * previously skipped here and misreported as corrupt). */
        int hash_bad = 0;
        for (unsigned int s = 0; s < 4; s++) {
            if (nca.section_contexts[s].header != NULL &&
                nca.section_contexts[s].superblock_hash_validity == VALIDITY_INVALID) {
                hash_bad = 1;
            }
        }
        if (hash_bad && nca.has_rights_id) {
            ticket_record_t *rec = ticket_record_for(nca.header.rights_id);
            if (rec != NULL && rec->gen != nca.crypto_type) {
                unsigned char alt[0x10];
                if (derive_titlekey_with_gen(ctx->tool_ctx, nca.crypto_type, rec->cipher, alt)) {
                    settings_replace_decrypted_titlekey(&ctx->tool_ctx->settings, rec->rights_id, alt);
                    printf("NSP_NCA_RETRY: keygen %u -> %u\n", (unsigned int)rec->gen, (unsigned int)nca.crypto_type);
                    fflush(stdout);
                    nca_free_section_contexts(&nca);
                    nca_init(&nca);
                    nca.file = ctx->file;
                    nca.tool_ctx = ctx->tool_ctx;
                    nca.is_cli_target = true;
                    nca.base_offset = entry_start;
                    nca.file_size = (size_t)entry_size;
                    nca_process(&nca);
                    fflush(stdout);
                }
            }
        }
        nca_free_section_contexts(&nca);
        printf("\nNSP_NCA_END: %s\n", name);
        fflush(stdout);

        processed++;
    }

    printf("\nNSP_RESULT: %u nca(s), %u skipped\n", processed, skipped);
    free(entries);
    free(string_table);
}
