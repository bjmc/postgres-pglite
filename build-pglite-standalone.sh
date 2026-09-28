#!/bin/bash
set -euo pipefail

### NOTES ###
# Builds PGlite as a standalone WASM module that runs on any WASI runtime
# (Wasmtime, Node's node:wasi, ...) without the emscripten JS glue.
# See the "Standalone build" section of README-PGLITE-DEV.md.
#
# Differences from build-pglite.sh:
#   - out-of-tree build in $BUILD_DIR, so the source tree stays clean
#   - native wasm exception handling for setjmp/longjmp (exnref encoding)
#   - WASMFS in-memory filesystem; share/ data ships as a tarball the host loads at startup
#   - no dynamic linking: extensions are not supported (yet)
#   - host I/O through the "pglite" import module (see pglite/src/pglitec/pglitec_standalone.c)
#
# $INSTALL_PREFIX is expected to point to the installation folder of various libraries built to wasm (see pglite-builder)
#############

SRC_DIR=$(pwd)
BUILD_DIR=${BUILD_DIR:-"$SRC_DIR/build/standalone"}
# final output folder
INSTALL_FOLDER=${INSTALL_FOLDER:-"/pglite/standalone"}

if [ -f "$SRC_DIR/config.status" ]; then
    echo "error: $SRC_DIR has been configured in-tree (probably by build-pglite.sh)."
    echo "The standalone build is an out-of-tree build and needs a clean source tree:"
    echo "run it from a separate checkout (e.g. 'git worktree add'), or 'make distclean' first."
    exit 1
fi

PGLITE_CFLAGS="-sWASM_BIGINT -sSUPPORT_LONGJMP=wasm -sWASM_EXNREF=1 -DPGLITE_STANDALONE -Wno-declaration-after-statement -Wno-macro-redefined -Wno-unused-function -Wno-missing-prototypes -Wno-incompatible-pointer-types"
if [ "${DEBUG:-false}" = true ]
then
    echo "pglite: building debug version of standalone module."
    PGLITE_CFLAGS="$PGLITE_CFLAGS -g"
else
    echo "pglite: building release version of standalone module."
    PGLITE_CFLAGS="$PGLITE_CFLAGS -O2"
    unset DEBUG
fi

mkdir -p "$BUILD_DIR"

# first build pglite-libc objects WITHOUT the overriding flags
emcc $PGLITE_CFLAGS -c "$SRC_DIR/pglite/src/pglitec/pglitec.c" -o "$BUILD_DIR/pglitec.o"
emcc $PGLITE_CFLAGS -c "$SRC_DIR/pglite/src/pglitec/pglitec_standalone.c" -o "$BUILD_DIR/pglitec_standalone.o"

PGLITE_CFLAGS="$PGLITE_CFLAGS \
-D__PGLITE__ \
-Dsystem=pgl_system -Dpopen=pgl_popen -Dpclose=pgl_pclose \
-Dgeteuid=pgl_geteuid -Dgetuid=pgl_getuid -Dgetpwuid=pgl_getpwuid \
-Dexit=pgl_exit \
-Dmunmap=pgl_munmap \
-Dfcntl=pgl_fcntl \
-Datexit=pgl_atexit \
-Dsetsockopt=pgl_setsockopt -Dgetsockopt=pgl_getsockopt -Dgetsockname=pgl_getsockname \
-Drecv=pgl_recv -Dsend=pgl_send -Dconnect=pgl_connect \
-Dpoll=pgl_poll \
-Dshmget=pgl_shmget -Dshmat=pgl_shmat -Dshmdt=pgl_shmdt -Dshmctl=pgl_shmctl \
-Dlongjmp=pgl_longjmp -Dsiglongjmp=pgl_siglongjmp"

echo "pglite: PGLITE_CFLAGS=$PGLITE_CFLAGS"

PGLITE_LDFLAGS="-sWASM_BIGINT -sUSE_PTHREADS=0 -sSUPPORT_LONGJMP=wasm -sWASM_EXNREF=1"
# `make` still builds the frontend programs (initdb, psql, ...); they are not used by the standalone module
PGLITE_LDFLAGS_EX="-sERROR_ON_UNDEFINED_SYMBOLS=0 -sALLOW_MEMORY_GROWTH $BUILD_DIR/pglitec.o $BUILD_DIR/pglitec_standalone.o"

CONFIGURE_PARAMS="\
ac_cv_exeext=.js \
--host wasm32-unknown-emscripten \
--disable-spinlocks \
--without-llvm  \
--without-pam \
--disable-largefile \
--with-openssl=no \
--without-readline \
--with-icu \
--with-includes=$INSTALL_PREFIX/include:$INSTALL_PREFIX/include/libxml2 \
--with-libraries=$INSTALL_PREFIX/lib \
--with-uuid=ossp \
--with-zlib \
--with-libxml \
--with-libxslt \
--with-template=emscripten \
--prefix=$INSTALL_FOLDER"

cd "$BUILD_DIR"

# Step 1: configure, if never done or this script changed since
if [ ! -f config.status ] || [ "$SRC_DIR/build-pglite-standalone.sh" -nt config.status ]; then
    LDFLAGS=$PGLITE_LDFLAGS \
    LDFLAGS_EX=$PGLITE_LDFLAGS_EX \
    ICU_CFLAGS="-I/install/libs/include" \
    ICU_LIBS="-L/install/libs/lib -licui18n -licuuc -licudata" \
    CFLAGS=${PGLITE_CFLAGS} emconfigure "$SRC_DIR/configure" $CONFIGURE_PARAMS || { echo 'error: emconfigure failed' ; exit 11; }
fi

# Step 2: make and install core
emmake make PORTNAME=emscripten -j || { echo 'error: emmake make PORTNAME=emscripten -j' ; exit 21; }
emmake make PORTNAME=emscripten install || { echo 'error: emmake make PORTNAME=emscripten install' ; exit 23; }

# Step 3: link the standalone module
# Functions the host calls, in addition to the EMSCRIPTEN_KEEPALIVE ones in pglitec*.c
STANDALONE_EXPORTS="_malloc,_free,_pgl_setPGliteActive,\
_PostgresMainLoopOnce,_PostgresMainLongJmp,_PostgresSendReadyForQueryIfNecessary,\
_pq_buffer_remaining_data,_ProcessStartupPacket,\
_pgl_startPGlite,_pgl_getMyProcPort,_pgl_sendConnData,_pgl_pq_flush"

STANDALONE_LDFLAGS="\
-sSTANDALONE_WASM=1 --no-entry \
-sWASMFS=1 \
-sWASM_BIGINT \
-sSUPPORT_LONGJMP=wasm -sWASM_EXNREF=1 \
-sSTACK_SIZE=8MB \
-sINITIAL_MEMORY=128MB \
-sALLOW_MEMORY_GROWTH \
-sERROR_ON_UNDEFINED_SYMBOLS=1 \
-sEXPORTED_FUNCTIONS=$STANDALONE_EXPORTS"

# the pglitec objects are linked in through LDFLAGS_EX; they are not make prerequisites, so always relink
rm -f src/backend/pglite.wasm
POSTGRES_PGLITE_FLAGS="$PGLITE_CFLAGS $STANDALONE_LDFLAGS" \
    emmake make PORTNAME=emscripten -C src/backend/ pglite X=.wasm || { echo 'error: emmake make PORTNAME=emscripten -C src/backend/ pglite' ; exit 31; }

# Step 4: the runtime filesystem (share/ data, ICU, static files), which the
# host unpacks into the module's in-memory filesystem before startup
FS_STAGING="$BUILD_DIR/fs-staging"
rm -rf "$FS_STAGING"
mkdir -p "$FS_STAGING/pglite/bin" "$FS_STAGING/pglite/share" "$FS_STAGING/home/postgres" "$FS_STAGING/tmp"
cp "$SRC_DIR/pglite/static/PGPASSFILE" "$FS_STAGING/home/postgres/.pgpass"
# postgres locates its share/ dir relative to its own executable, which must exist
cp "$SRC_DIR/pglite/static/empty" "$FS_STAGING/pglite/bin/initdb"
cp "$SRC_DIR/pglite/static/empty" "$FS_STAGING/pglite/bin/postgres"
chmod 755 "$FS_STAGING/pglite/bin/"*
cp -r "$INSTALL_FOLDER/share/postgresql" "$FS_STAGING/pglite/share/postgresql"
cp "$SRC_DIR/pglite/static/password" "$FS_STAGING/pglite/password"
cp "$SRC_DIR/pglite/static/locale-a" "$FS_STAGING/pglite/locale-a"
cp -r "$SRC_DIR/pglite/static/minimal-icu/76.1" "$FS_STAGING/pglite/icu"

mkdir -p "$INSTALL_FOLDER/bin"
cp src/backend/pglite.wasm "$INSTALL_FOLDER/bin/pglite-standalone.wasm"
tar -C "$FS_STAGING" -czf "$INSTALL_FOLDER/bin/pglite-standalone-fs.tar.gz" .
echo "pglite: built $INSTALL_FOLDER/bin/pglite-standalone.wasm and $INSTALL_FOLDER/bin/pglite-standalone-fs.tar.gz"
