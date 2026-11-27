// nszunpack — converts NSZ containers back to plain NSP.
//
// NSZ is an NSP whose NCAs may be stored as NCZ: the NCA header (0x4000) is
// kept byte for byte, the body is zstd-compressed plaintext, and a 0x4000-
// resident header lists the sections so the plaintext can be re-encrypted the
// way the console expects.
//
// Layout of an NCZ (verified against real files):
//   0x0000  NCA header, as-is (still encrypted)
//   0x4000  magic "NCZSECTN", u64 section count, then N section records
//             u64 offset, u64 size, u8 cryptType, u8 pad[7], u64 pad2,
//             u8 key[16], u8 counter[16]
//           optional "NCZBLOCK" header for random-access block compression
//           then a zstd stream that expands to everything from 0x4000 on.
//
// Re-encryption: cryptType 1 is "none" and stays plaintext; cryptType 3 is
// AES-128-CTR with IV = counter[0..7] || big-endian(offset >> 4) — that is
// exactly the IV the console (and hactool) derives from the NCA section table,
// so reconstructing it byte for byte is what makes the rebuilt NSP verifiable.
//
// Build: see scripts/build-nszunpack.sh (links vendored mbedtls + zstd).

#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <sys/stat.h>
#include <sys/types.h>

#include <zstd.h>
#include <mbedtls/aes.h>
#include <mbedtls/sha256.h>

#define PFS0_MAGIC "PFS0"
#define NCZ_MAGIC "NCZSECTN"
#define NCZ_BLOCK_MAGIC "NCZBLOCK"
#define NCA_HEADER_SIZE 0x4000u

// ---------- little helpers ----------

static uint64_t rd64(const unsigned char *p) {
    uint64_t v = 0;
    for (int i = 7; i >= 0; i--) v = (v << 8) | p[i];
    return v;
}

static uint32_t rd32(const unsigned char *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static void wr64(unsigned char *p, uint64_t v) {
    for (int i = 0; i < 8; i++) { p[i] = (unsigned char)(v & 0xFF); v >>= 8; }
}

static void wr32(unsigned char *p, uint32_t v) {
    for (int i = 0; i < 4; i++) { p[i] = (unsigned char)(v & 0xFF); v >>= 8; }
}

static void fail(const char *msg) {
    fprintf(stderr, "nszunpack: %s\n", msg);
    printf("NSZ_ERROR: %s\n", msg);
    exit(2);
}

// ---------- PFS0 ----------

typedef struct {
    char name[256];
    uint64_t offset;   // absolute in the source file
    uint64_t size;
} pfs_entry_t;

typedef struct {
    pfs_entry_t *entries;
    uint32_t count;
} pfs_t;

static void pfs0_read(FILE *f, pfs_t *out) {
    unsigned char hdr[0x10];
    if (fread(hdr, 1, sizeof hdr, f) != sizeof hdr || memcmp(hdr, PFS0_MAGIC, 4) != 0) {
        fail("not a PFS0/NSZ container");
    }
    uint32_t count = rd32(hdr + 4);
    uint32_t strtab = rd32(hdr + 8);
    if (count == 0 || count > 4096) fail("implausible PFS0 entry count");

    unsigned char *table = malloc((size_t)count * 0x18 + strtab);
    if (!table) fail("out of memory");
    if (fread(table, 1, (size_t)count * 0x18 + strtab, f) != (size_t)count * 0x18 + strtab) {
        fail("truncated PFS0 table");
    }
    out->entries = calloc(count, sizeof(pfs_entry_t));
    out->count = count;
    uint64_t base = 0x10 + (uint64_t)count * 0x18 + strtab;
    for (uint32_t i = 0; i < count; i++) {
        const unsigned char *e = table + (size_t)i * 0x18;
        out->entries[i].offset = base + rd64(e);
        out->entries[i].size = rd64(e + 8);
        uint32_t name_ofs = rd32(e + 16);
        if (name_ofs < strtab) {
            const char *s = (const char *)(table + (size_t)count * 0x18 + name_ofs);
            size_t len = strnlen(s, strtab - name_ofs);
            if (len >= sizeof out->entries[i].name) len = sizeof out->entries[i].name - 1;
            memcpy(out->entries[i].name, s, len);
        }
    }
    free(table);
}

static int ends_with(const char *s, const char *suffix) {
    size_t a = strlen(s), b = strlen(suffix);
    return a >= b && strcmp(s + a - b, suffix) == 0;
}

// ---------- NCZ ----------

typedef struct {
    uint64_t offset;
    uint64_t size;
    unsigned char crypt_type;
    unsigned char key[16];
    unsigned char counter[16];
} ncz_section_t;

typedef struct {
    ncz_section_t *sections;
    unsigned int section_count;
    int block_compressed;
    unsigned char block_exponent;
    uint32_t block_count;
    uint64_t decompressed_size;
    uint32_t *block_sizes;     // compressed size per block (block mode)
    uint64_t data_offset;      // where the zstd payload starts
} ncz_t;

#define NCZ_HDR_WINDOW 0x2000u

// NCZ header:
//   0x4000: "NCZSECTN" + u64 sectionCount
//   then sectionCount records of 64 bytes (offset, size, cryptType, pad, key, counter)
//   optionally "NCZBLOCK" + u8 version/type/+2, u32 blockCount, u64 bodySize,
//   u32 compressedSize[blockCount]
//
// Update packages routinely carry hundreds of sections (one sample update has
// 417, another has 692), so the table cannot be a fixed array
// and the header window has to grow with it.
static void ncz_read(FILE *f, uint64_t entry_offset, uint64_t entry_size, ncz_t *out, const char *name) {
    memset(out, 0, sizeof *out);
    out->block_compressed = -1;
    if (entry_size <= NCA_HEADER_SIZE) fail("NCZ entry too small");
    uint64_t avail = entry_size - NCA_HEADER_SIZE;
    if (avail < 16) fail("NCZ entry too small");

    unsigned char head[16];
    if (fseeko(f, (off_t)(entry_offset + NCA_HEADER_SIZE), SEEK_SET) != 0 ||
        fread(head, 1, sizeof head, f) != sizeof head) {
        fail("cannot read NCZ header");
    }
    if (memcmp(head, NCZ_MAGIC, 8) != 0) {
        // Not NCZ after all — a plain NCA stored under a .ncz name.
        out->section_count = 0;
        return;
    }
    uint64_t count = rd64(head + 8);
    if (count == 0 || count > (1ull << 20)) fail("unsupported NCZ section count");

    uint64_t need = 16 + count * 64 + 0x10000;   // section table + block header/table
    if (need > avail) need = avail;
    unsigned char *hdr = malloc((size_t)need);
    if (!hdr) fail("out of memory");
    if (fseeko(f, (off_t)(entry_offset + NCA_HEADER_SIZE), SEEK_SET) != 0 ||
        fread(hdr, 1, (size_t)need, f) != (size_t)need) {
        fail("cannot read NCZ header");
    }

    out->section_count = (unsigned int)count;
    out->block_compressed = 0;   // a real NCZ; 1 only if the block header follows
    out->sections = calloc((size_t)count, sizeof(ncz_section_t));
    if (!out->sections) fail("out of memory");
    uint64_t cursor = 16;
    for (unsigned int i = 0; i < (unsigned int)count; i++) {
        // Some writers repeat the magic before every record; tolerate both.
        if (cursor + 8 <= need && memcmp(hdr + cursor, NCZ_MAGIC, 8) == 0) cursor += 8;
        if (cursor + 64 > need) fail("NCZ header truncated");
        ncz_section_t *sc = &out->sections[i];
        sc->offset = rd64(hdr + cursor);
        sc->size = rd64(hdr + cursor + 8);
        sc->crypt_type = hdr[cursor + 16];
        memcpy(sc->key, hdr + cursor + 32, 16);
        memcpy(sc->counter, hdr + cursor + 48, 16);
        cursor += 64;
    }
    // Optional block compression header.
    if (cursor + 24 <= need && memcmp(hdr + cursor, NCZ_BLOCK_MAGIC, 8) == 0) {
        out->block_compressed = 1;
        out->block_exponent = hdr[cursor + 11];
        out->block_count = rd32(hdr + cursor + 12);
        out->decompressed_size = rd64(hdr + cursor + 16);
        cursor += 24;
        if (out->block_count == 0 || (uint64_t)out->block_count > (avail / 4)) fail("NCZ block table implausible");
        if (cursor + (uint64_t)out->block_count * 4 > need) fail("NCZ block table truncated");
        out->block_sizes = calloc(out->block_count, sizeof(uint32_t));
        if (!out->block_sizes) fail("out of memory");
        for (uint32_t i = 0; i < out->block_count; i++)
            out->block_sizes[i] = rd32(hdr + cursor + (uint64_t)i * 4);
        cursor += (uint64_t)out->block_count * 4;
    }
    out->data_offset = entry_offset + NCA_HEADER_SIZE + cursor;
    (void)entry_size;
    (void)name;
    free(hdr);
}

static void aes_ctr_encrypt(unsigned char *buf, size_t len, const unsigned char key[16],
                            const unsigned char iv_in[16]) {
    unsigned char iv[16];
    memcpy(iv, iv_in, 16);
    mbedtls_aes_context aes;
    mbedtls_aes_init(&aes);
    mbedtls_aes_setkey_enc(&aes, key, 128);
    size_t nc_off = 0;
    unsigned char stream_block[16];
    mbedtls_aes_crypt_ctr(&aes, len, &nc_off, iv, stream_block, buf, buf);
    mbedtls_aes_free(&aes);
}

static void counter_iv(const ncz_section_t *s, unsigned char iv[16]) {
    memcpy(iv, s->counter, 8);
    uint64_t block = s->offset >> 4;
    for (int i = 0; i < 8; i++) iv[8 + i] = (unsigned char)((block >> (8 * (7 - i)) & 0xFF));
}

// Decompresses the NCZ payload into `out_path`, producing a complete NCA:
// header copied verbatim, body plaintext, encrypted sections re-encrypted.
//
// Two payload shapes exist:
//   * one continuous zstd stream covering the whole body (most base titles);
//   * NCZBLOCK: the body split into fixed-size blocks, each its own zstd frame
//     with its compressed size listed in the header (every update package
//     seen so far, and some bases).
static int ncz_extract(FILE *src, uint64_t entry_offset, uint64_t entry_size, const ncz_t *ncz,
                       const char *out_path, const char *label, uint64_t *written) {
    FILE *out = fopen(out_path, "wb+");
    if (!out) fail("cannot create output file");

    // 1. header, untouched.
    if (fseeko(src, (off_t)entry_offset, SEEK_SET) != 0) fail("cannot seek to NCA header");
    unsigned char *hdr = malloc(NCA_HEADER_SIZE);
    if (!hdr) fail("out of memory");
    if (fread(hdr, 1, NCA_HEADER_SIZE, src) != NCA_HEADER_SIZE) fail("truncated NCA header");
    fwrite(hdr, 1, NCA_HEADER_SIZE, out);
    free(hdr);

    // 2. body.
    if (fseeko(src, (off_t)ncz->data_offset, SEEK_SET) != 0) fail("cannot seek to NCZ payload");
    uint64_t payload_bytes = entry_size - (ncz->data_offset - entry_offset);
    uint64_t body_bytes = 0;

    if (ncz->block_compressed == 1) {
        if (ncz->block_exponent < 10 || ncz->block_exponent > 26) {
            printf("NSZ_ERROR: implausible NCZ block exponent %u in %s\n", ncz->block_exponent, label);
            return -1;
        }
        size_t unit = (size_t)1 << ncz->block_exponent;
        size_t max_in = unit;
        for (uint32_t i = 0; i < ncz->block_count; i++)
            if (ncz->block_sizes[i] > max_in) max_in = ncz->block_sizes[i];
        unsigned char *inbuf = malloc(max_in + 8);
        unsigned char *outbuf = malloc(unit);
        if (!inbuf || !outbuf) fail("out of memory");
        uint64_t remaining = ncz->decompressed_size;
        uint64_t consumed = 0;
        for (uint32_t i = 0; i < ncz->block_count; i++) {
            size_t csize = ncz->block_sizes[i];
            size_t usize = unit;
            if (remaining < (uint64_t)usize) usize = (size_t)remaining;
            consumed += csize;
            if (csize == 0 || consumed > payload_bytes) {
                printf("NSZ_ERROR: NCZ block table overruns payload in %s\n", label);
                return -1;
            }
            if (fread(inbuf, 1, csize, src) != csize) {
                printf("NSZ_ERROR: NCZ block %u truncated in %s\n", i, label);
                return -1;
            }
            size_t got = ZSTD_decompress(outbuf, usize, inbuf, csize);
            if (ZSTD_isError(got) || got != usize) {
                // Writers store a block verbatim when zstd would not shrink it;
                // such a block carries compressedSize == blockSize and has no
                // frame magic at all.
                if (csize == usize) {
                    memcpy(outbuf, inbuf, usize);
                    got = usize;
                } else {
                    printf("NSZ_ERROR: zstd block %u corrupt in %s\n", i, label);
                    return -1;
                }
            }
            fwrite(outbuf, 1, usize, out);
            body_bytes += usize;
            remaining -= usize;
        }
        free(inbuf); free(outbuf);
        if (remaining != 0) {
            printf("NSZ_ERROR: NCZ blocks cover %llu of %llu bytes in %s\n",
                   (unsigned long long)(ncz->decompressed_size - remaining),
                   (unsigned long long)ncz->decompressed_size, label);
            return -1;
        }
    } else {
        ZSTD_DStream *ds = ZSTD_createDStream();
        if (!ds) fail("zstd init failed");
        ZSTD_initDStream(ds);

        const size_t chunk = 1u << 20;
        unsigned char *inbuf = malloc(chunk);
        unsigned char *outbuf = malloc(chunk);
        if (!inbuf || !outbuf) fail("out of memory");
        uint64_t read_total = 0;
        size_t last_ret = 1;

        while (read_total < payload_bytes) {
            size_t want = chunk;
            if ((uint64_t)want > payload_bytes - read_total) want = (size_t)(payload_bytes - read_total);
            size_t got = fread(inbuf, 1, want, src);
            if (got == 0) break;
            read_total += got;
            ZSTD_inBuffer in = { inbuf, got, 0 };
            while (in.pos < in.size) {
                ZSTD_outBuffer ob = { outbuf, chunk, 0 };
                last_ret = ZSTD_decompressStream(ds, &ob, &in);
                if (ZSTD_isError(last_ret)) {
                    fprintf(stderr, "nszunpack: zstd error on %s: %s\n", label, ZSTD_getErrorName(last_ret));
                    printf("NSZ_ERROR: zstd stream corrupt in %s\n", label);
                    return -1;
                }
                if (ob.pos) {
                    fwrite(outbuf, 1, ob.pos, out);
                    body_bytes += ob.pos;
                }
            }
        }
        free(inbuf); free(outbuf);
        ZSTD_freeDStream(ds);
        if (last_ret != 0) {
            fprintf(stderr, "nszunpack: zstd stream for %s ended early (ret=%zu)\n", label, last_ret);
            printf("NSZ_ERROR: truncated zstd stream in %s\n", label);
            return -1;
        }
    }

    // 3. re-encrypt the sections the console expects to be encrypted.
    //    Chunked so a 4 GB section does not need a 4 GB buffer; CTR state
    //    carries across chunks via nc_off, so the keystream stays continuous.
    if (fseeko(out, 0, SEEK_END) != 0) fail("seek failed");
    off_t file_size = ftello(out);
    const size_t enc_chunk = 8u << 20;
    unsigned char *buf = malloc(enc_chunk);
    if (!buf) fail("out of memory");

    for (unsigned int i = 0; i < ncz->section_count; i++) {
        const ncz_section_t *sc = &ncz->sections[i];
        if (sc->crypt_type == 1) continue;          // plaintext
        if (sc->size == 0) continue;
        if ((uint64_t)file_size < sc->offset + sc->size) {
            fprintf(stderr, "nszunpack: section %u runs past EOF in %s\n", i, label);
            printf("NSZ_ERROR: section out of range in %s\n", label);
            free(buf);
            return -1;
        }
        unsigned char iv[16];
        counter_iv(sc, iv);
        mbedtls_aes_context aes;
        mbedtls_aes_init(&aes);
        mbedtls_aes_setkey_enc(&aes, sc->key, 128);
        size_t nc_off = 0;
        unsigned char stream_block[16] = {0};
        uint64_t done = 0;
        while (done < sc->size) {
            size_t step = enc_chunk;
            if ((uint64_t)step > sc->size - done) step = (size_t)(sc->size - done);
            if (fseeko(out, (off_t)(sc->offset + done), SEEK_SET) != 0) fail("seek failed");
            if (fread(buf, 1, step, out) != step) fail("short read on section");
            mbedtls_aes_crypt_ctr(&aes, step, &nc_off, iv, stream_block, buf, buf);
            if (fseeko(out, (off_t)(sc->offset + done), SEEK_SET) != 0) fail("seek failed");
            if (fwrite(buf, 1, step, out) != step) fail("short write on section");
            done += step;
        }
        mbedtls_aes_free(&aes);
    }
    free(buf);

    *written = (uint64_t)file_size;
    fclose(out);
    return 0;
}

static int sha256_file(const char *path, unsigned char out[32]) {
    FILE *f = fopen(path, "rb");
    if (!f) return -1;
    mbedtls_sha256_context ctx;
    mbedtls_sha256_init(&ctx);
    mbedtls_sha256_starts(&ctx, 0);
    unsigned char buf[1 << 20];
    size_t got;
    while ((got = fread(buf, 1, sizeof buf, f)) > 0) mbedtls_sha256_update(&ctx, buf, got);
    fclose(f);
    mbedtls_sha256_finish(&ctx, out);
    return 0;
}

// CNMT XML inside NSZ lists <Id>/<Hash> for every content, which is the
// ground truth for "did our zstd + re-encryption reproduce the original NCA".
typedef struct { char id[64]; char hash[80]; } content_expect_t;

static int read_expectations(FILE *src, const pfs_t *pfs, content_expect_t *out, int max_out) {
    int count = 0;
    for (uint32_t i = 0; i < pfs->count && count < max_out; i++) {
        if (!ends_with(pfs->entries[i].name, ".cnmt.xml")) continue;
        uint64_t size = pfs->entries[i].size;
        if (size == 0 || size > (1 << 20)) continue;
        char *text = calloc(1, (size_t)size + 1);
        if (!text) continue;
        fseeko(src, (off_t)pfs->entries[i].offset, SEEK_SET);
        fread(text, 1, (size_t)size, src);
        char *cursor = text;
        while ((cursor = strstr(cursor, "<Content>")) != NULL) {
            char *id = strstr(cursor, "<Id>");
            char *hash = strstr(cursor, "<Hash>");
            char *end = strstr(cursor, "</Content>");
            if (!id || !hash || (end && id > end)) { cursor += 9; continue; }
            char idbuf[64] = {0}, hbuf[80] = {0};
            sscanf(id + 4, "%63[^<]", idbuf);
            sscanf(hash + 6, "%79[^<]", hbuf);
            if (strlen(idbuf) == 32 && strlen(hbuf) == 64) {
                memcpy(out[count].id, idbuf, 33);
                memcpy(out[count].hash, hbuf, 65);
                count++;
            }
            cursor = end ? end : cursor + 9;
        }
        free(text);
    }
    return count;
}

// ---------- commands ----------

static void cmd_info(const char *path) {
    FILE *f = fopen(path, "rb");
    if (!f) fail("cannot open input");
    pfs_t pfs;
    pfs0_read(f, &pfs);
    printf("NSZ_CONTAINER: %s\n", path);
    printf("NSZ_ENTRIES: %u\n", pfs.count);
    unsigned ncz_count = 0;
    uint64_t total_out = 0;
    for (uint32_t i = 0; i < pfs.count; i++) {
        pfs_entry_t *e = &pfs.entries[i];
        if (ends_with(e->name, ".ncz")) {
            ncz_t ncz;
            ncz_read(f, e->offset, e->size, &ncz, e->name);
            if (ncz.block_compressed == -1) {
                printf("NSZ_ENTRY: %s size=%llu kind=nca\n", e->name, (unsigned long long)e->size);
                total_out += e->size;
                continue;
            }
            printf("NSZ_ENTRY: %s size=%llu kind=ncz sections=%u block=%d\n",
                   e->name, (unsigned long long)e->size, ncz.section_count, ncz.block_compressed);
            ncz_count++;
            total_out += e->size; // upper bound; real size printed after unpack
            free(ncz.block_sizes);
            free(ncz.sections);
        } else {
            printf("NSZ_ENTRY: %s size=%llu kind=file\n", e->name, (unsigned long long)e->size);
            total_out += e->size;
        }
    }
    printf("NSZ_SUMMARY: ncz=%u approx_bytes=%llu\n", ncz_count, (unsigned long long)total_out);
    printf("NSZ_OK\n");
    free(pfs.entries);
    fclose(f);
}

// mkdir -p, so an output path inside fresh directories works.
static void mkdir_p(const char *path) {
    char buf[1024];
    snprintf(buf, sizeof buf, "%s", path);
    for (char *p = buf + 1; *p; p++) {
        if (*p != '/') continue;
        *p = 0;
        mkdir(buf, 0700);
        *p = '/';
    }
    mkdir(buf, 0700);
}

static void cmd_unpack(const char *path, const char *out_path) {
    FILE *f = fopen(path, "rb");
    if (!f) fail("cannot open input");
    pfs_t pfs;
    pfs0_read(f, &pfs);

    char tmpdir[512];
    snprintf(tmpdir, sizeof tmpdir, "%s.nszwork", out_path);
    mkdir_p(tmpdir);

    // Pass 1: materialise every NCA into the work directory.
    uint64_t *sizes = calloc(pfs.count, sizeof(uint64_t));
    char **names = calloc(pfs.count, sizeof(char *));
    for (uint32_t i = 0; i < pfs.count; i++) {
        pfs_entry_t *e = &pfs.entries[i];
        char tmp[700];
        snprintf(tmp, sizeof tmp, "%s/%08u.bin", tmpdir, i);
        if (ends_with(e->name, ".ncz")) {
            ncz_t ncz;
            ncz_read(f, e->offset, e->size, &ncz, e->name);
            if (ncz.block_compressed == -1) {
                // Plain NCA under a compressed name.
                if (fseeko(f, (off_t)e->offset, SEEK_SET) != 0) fail("seek failed");
                FILE *o = fopen(tmp, "wb");
                if (!o) fail("cannot create work file (output directory missing?)");
                unsigned char buf[1 << 20];
                uint64_t left = e->size;
                while (left) {
                    size_t got = fread(buf, 1, left > sizeof buf ? sizeof buf : (size_t)left, f);
                    if (!got) break;
                    fwrite(buf, 1, got, o);
                    left -= got;
                }
                fclose(o);
                sizes[i] = e->size;
            } else {
                printf("NSZ_PROGRESS: unpacking %s\n", e->name);
                fflush(stdout);
                if (ncz_extract(f, e->offset, e->size, &ncz, tmp, e->name, &sizes[i]) != 0) {
                    fail("ncz extraction failed");
                }
                free(ncz.block_sizes);
            free(ncz.sections);
            }
            size_t len = strlen(e->name);
            names[i] = strdup(e->name);
            names[i][len - 4] = 0;
            strcat(names[i], ".nca");
        } else {
            if (fseeko(f, (off_t)e->offset, SEEK_SET) != 0) fail("seek failed");
            FILE *o = fopen(tmp, "wb");
            if (!o) fail("cannot create work file (output directory missing?)");
            unsigned char buf[1 << 20];
            uint64_t left = e->size;
            while (left) {
                size_t got = fread(buf, 1, left > sizeof buf ? sizeof buf : (size_t)left, f);
                if (!got) break;
                fwrite(buf, 1, got, o);
                left -= got;
            }
            fclose(o);
            sizes[i] = e->size;
            names[i] = strdup(e->name);
        }
    }

    // 1b. Verify every produced NCA against the CNMT XML inside the container.
    content_expect_t *expect = calloc(pfs.count, sizeof(content_expect_t));
    int expect_count = read_expectations(f, &pfs, expect, (int)pfs.count);
    int matches = 0, mismatches = 0, unknowns = 0;
    for (uint32_t i = 0; i < pfs.count; i++) {
        if (!ends_with(names[i], ".nca")) continue;
        char tmp[700];
        snprintf(tmp, sizeof tmp, "%s/%08u.bin", tmpdir, i);
        unsigned char digest[32];
        if (sha256_file(tmp, digest) != 0) continue;
        char hex[65] = {0};
        for (int b = 0; b < 32; b++) snprintf(hex + b * 2, 3, "%02x", digest[b]);
        char base_id[33] = {0};
        memcpy(base_id, names[i], 32);
        const char *expected = NULL;
        for (int k = 0; k < expect_count; k++) {
            if (strncasecmp(expect[k].id, base_id, 32) == 0) { expected = expect[k].hash; break; }
        }
        if (expected) {
            int ok = strcasecmp(expected, hex) == 0;
            printf("NSZ_HASH: %s sha256=%s expected=%s match=%s\n", names[i], hex, expected, ok ? "yes" : "no");
            if (ok) matches++; else mismatches++;
        } else {
            printf("NSZ_HASH: %s sha256=%s expected=none match=unknown\n", names[i], hex);
            unknowns++;
        }
        fflush(stdout);
    }
    printf("NSZ_HASH_SUMMARY: match=%d mismatch=%d unknown=%d\n", matches, mismatches, unknowns);
    free(expect);

    // Pass 2: write the NSP.
    FILE *o = fopen(out_path, "wb");
    if (!o) fail("cannot create output NSP");
    uint32_t strtab_size = 0;
    for (uint32_t i = 0; i < pfs.count; i++) strtab_size += (uint32_t)strlen(names[i]) + 1;
    uint64_t header_size = 0x10 + (uint64_t)pfs.count * 0x18 + strtab_size;

    unsigned char *tbl = calloc(pfs.count, 0x18);
    char *strtab = malloc(strtab_size);
    uint32_t soff = 0;
    uint64_t data = header_size;
    for (uint32_t i = 0; i < pfs.count; i++) {
        wr64(tbl + (size_t)i * 0x18, data - header_size);
        wr64(tbl + (size_t)i * 0x18 + 8, sizes[i]);
        wr32(tbl + (size_t)i * 0x18 + 16, soff);
        memcpy(strtab + soff, names[i], strlen(names[i]));
        soff += (uint32_t)strlen(names[i]) + 1;
        data += sizes[i];
    }

    unsigned char hdr[0x10] = {0};
    memcpy(hdr, PFS0_MAGIC, 4);
    wr32(hdr + 4, pfs.count);
    wr32(hdr + 8, strtab_size);
    fwrite(hdr, 1, sizeof hdr, o);
    fwrite(tbl, 1, (size_t)pfs.count * 0x18, o);
    fwrite(strtab, 1, strtab_size, o);
    for (uint32_t i = 0; i < pfs.count; i++) {
        char tmp[700];
        snprintf(tmp, sizeof tmp, "%s/%08u.bin", tmpdir, i);
        FILE *in = fopen(tmp, "rb");
        if (!in) fail("work file lost");
        unsigned char buf[1 << 20];
        size_t got;
        while ((got = fread(buf, 1, sizeof buf, in)) > 0) fwrite(buf, 1, got, o);
        fclose(in);
        unlink(tmp);
    }
    fclose(o);
    rmdir(tmpdir);

    printf("NSZ_CONVERTED: %s\n", out_path);
    for (uint32_t i = 0; i < pfs.count; i++) free(names[i]);
    free(names); free(sizes); free(tbl); free(strtab); free(pfs.entries);
    fclose(f);
    printf("NSZ_OK\n");
}

int main(int argc, char **argv) {
    if (argc < 3) {
        fprintf(stderr, "usage: nszunpack info <file.nsz> | nszunpack unpack <file.nsz> <out.nsp>\n");
        return 1;
    }
    if (strcmp(argv[1], "info") == 0) {
        cmd_info(argv[2]);
        return 0;
    }
    if (strcmp(argv[1], "unpack") == 0) {
        if (argc < 4) { fprintf(stderr, "unpack needs an output path\n"); return 1; }
        cmd_unpack(argv[2], argv[3]);
        return 0;
    }
    fprintf(stderr, "unknown command %s\n", argv[1]);
    return 1;
}
