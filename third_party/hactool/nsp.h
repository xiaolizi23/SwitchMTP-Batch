#ifndef HACTOOL_NSP_H
#define HACTOOL_NSP_H

#include <stdio.h>
#include "types.h"
#include "utils.h"

typedef struct {
    FILE *file;
    hactool_ctx_t *tool_ctx;
} nsp_ctx_t;

/* Walks the PFS0 table of an NSP and verifies every .nca entry in place.
 *
 * hactool could already verify a standalone .nca, and an XCI's header, but an
 * NSP was only ever listed: its NCAs were never opened, so a "-y -t pfs0" run
 * could not say whether the package was retail-signed. This walker seeks to
 * each entry instead of extracting it, which keeps a 15 GB package a read-only
 * operation on the original file.
 *
 * Output markers consumed by the app:
 *   NSP_NCA_BEGIN: <entry name>
 *   ...nca_print output for that entry...
 *   NSP_NCA_END: <entry name>
 *   NSP_RESULT: <processed> nca(s), <skipped> skipped
 */
void nsp_process(nsp_ctx_t *ctx);

#endif
