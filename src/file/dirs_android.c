/*
 * This file is part of libaacs
 * Copyright (C) 2026  <your name> <your@address>
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 *
 * This library is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with this library. If not, see
 * <http://www.gnu.org/licenses/>.
 */

#ifdef HAVE_CONFIG_H
# include "config.h"
#endif

#include "dirs.h"

#include "util/strutl.h"
#include "util/macro.h"
#include "util/logging.h"

#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/types.h>

/*
 * Return p if it is usable, NULL otherwise. Ownership is taken either way,
 * so that candidates can be chained without a free at each step.
 */
static char *_accept(char *p, int mode)
{
    if (!p) {
        return NULL;
    }
    if (access(p, mode)) {
        BD_DEBUG(DBG_DIR, "%s is not usable\n", p);
        X_FREE(p);
        return NULL;
    }
    BD_DEBUG(DBG_DIR, "using %s\n", p);
    return p;
}

/*
 * Root of the primary shared storage volume. Caller frees. One directory
 * under four names, none of them guaranteed on a given device:
 * EXTERNAL_STORAGE is set by the runtime in application processes,
 * /storage/emulated/<user> is where it points (the user is encoded in the
 * uid, one per 100000), the last two are aliases. Write access is needed
 * too: the key cache lands here.
 */
static char *_shared_storage_root(void)
{
    char *dir;

    const char *env = getenv("EXTERNAL_STORAGE");
    if (env && *env) {
        dir = _accept(str_dup(env), R_OK | W_OK | X_OK);
        if (dir) {
            return dir;
        }
    }

    dir = _accept(str_printf("/storage/emulated/%u", (unsigned)(getuid() / 100000)),
                  R_OK | W_OK | X_OK);
    if (dir) {
        return dir;
    }

    dir = _accept(str_dup("/storage/self/primary"), R_OK | W_OK | X_OK);
    if (dir) {
        return dir;
    }

    return _accept(str_dup("/sdcard"), R_OK | W_OK | X_OK);
}

char *file_get_config_home(void)
{
    /* An application that knows where it wants the key database keeps
     * control, and never reaches the platform default below. */
    const char *aacs_home = getenv("AACS_HOME");
    if (aacs_home && *aacs_home) {
        return str_dup(aacs_home);
    }

    const char *xdg_home = getenv("XDG_CONFIG_HOME");
    if (xdg_home && *xdg_home) {
        return str_dup(xdg_home);
    }

    /* $HOME is not used, unlike dirs_xdg.c: it is unset in application
     * processes and misleading in a shell. */

    return _shared_storage_root();
}

char *file_get_cache_home(void)
{
    const char *xdg_cache = getenv("XDG_CACHE_HOME");
    if (xdg_cache && *xdg_cache) {
        return str_dup(xdg_cache);
    }

    return _shared_storage_root();
}

char *file_get_data_home(void)
{
    const char *xdg_home = getenv("XDG_DATA_HOME");
    if (xdg_home && *xdg_home) {
        return str_dup(xdg_home);
    }

    return _shared_storage_root();
}

const char *file_get_config_system(const char *dir)
{
    /* No system wide configuration on Android. NULL on the first call ends
     * the caller's iteration: the list is empty, not missing. */
    (void)dir;
    return NULL;
}
