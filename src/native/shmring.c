//
// POSIX shared memory exposed as an ArrayBuffer for com/busshm.coffee.
//
// open(name, bytes[, create]) returns {buffer, created}.  The first opener
// sizes the segment; mappings are released with their ArrayBuffers.  The
// segment persists until unlink(name) or reboot.
//
// MAP_SHARED makes Atomics operations process-shared.  Atomics.wait remains
// process-local because V8's futex table is process-local.

#include <node_api.h>

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

// A segment name is at most PSHMNAMLEN (31 on Darwin) bytes with its
// leading slash.
#define NAME_MAX_LEN 64

typedef struct {
  void  *addr;
  size_t len;
} mapping;

static void finalize_map(napi_env env, void *data, void *hint) {
  (void)env;
  (void)data;
  mapping *m = (mapping *)hint;
  if (m) {
    munmap(m->addr, m->len);
    free(m);
  }
}

static napi_value throw_errno(napi_env env, const char *what, int err) {
  char msg[256];
  snprintf(msg, sizeof(msg), "%s: %s", what, strerror(err));
  napi_throw_error(env, NULL, msg);
  return NULL;
}

static napi_value Open(napi_env env, napi_callback_info info) {
  size_t argc = 3;
  napi_value argv[3];
  napi_get_cb_info(env, info, &argc, argv, NULL, NULL);
  if (argc < 2) {
    napi_throw_error(env, NULL, "open(name, bytes[, create])");
    return NULL;
  }
  bool create = true;
  if (argc >= 3) napi_get_value_bool(env, argv[2], &create);

  char name[NAME_MAX_LEN];
  size_t nlen = 0;
  if (napi_get_value_string_utf8(env, argv[0], name, sizeof(name), &nlen) != napi_ok) {
    napi_throw_error(env, NULL, "open: name must be a string");
    return NULL;
  }
  int64_t bytes = 0;
  if (napi_get_value_int64(env, argv[1], &bytes) != napi_ok || bytes <= 0) {
    napi_throw_error(env, NULL, "open: bytes must be a positive integer");
    return NULL;
  }

  int created = 0;
  int fd = create ? shm_open(name, O_RDWR | O_CREAT | O_EXCL, 0600) : -1;
  if (!create) {
    fd = shm_open(name, O_RDWR, 0600);
    if (fd < 0) return throw_errno(env, "shm_open", errno);
    struct stat st;
    if (fstat(fd, &st) != 0 || st.st_size < bytes) {
      close(fd);
      napi_throw_error(env, NULL, "shm segment is smaller than the ring");
      return NULL;
    }
  } else if (fd >= 0) {
    created = 1;
    if (ftruncate(fd, (off_t)bytes) != 0) {
      int err = errno;
      close(fd);
      shm_unlink(name);
      return throw_errno(env, "shm ftruncate", err);
    }
  } else if (errno == EEXIST) {
    fd = shm_open(name, O_RDWR, 0600);
    if (fd < 0) return throw_errno(env, "shm_open", errno);
    // The creator sizes the segment after it opens it, so a process that
    // arrives in between sees length zero.  200 us a turn for 200 ms.
    struct stat st;
    for (int i = 0; i < 1000; i++) {
      if (fstat(fd, &st) == 0 && st.st_size >= bytes) break;
      usleep(200);
    }
    if (fstat(fd, &st) != 0 || st.st_size < bytes) {
      close(fd);
      napi_throw_error(env, NULL, "shm segment is smaller than the ring");
      return NULL;
    }
  } else {
    return throw_errno(env, "shm_open", errno);
  }

  void *addr = mmap(NULL, (size_t)bytes, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
  int err = errno;
  close(fd);
  if (addr == MAP_FAILED) return throw_errno(env, "mmap", err);

  mapping *m = (mapping *)malloc(sizeof(mapping));
  if (!m) {
    munmap(addr, (size_t)bytes);
    napi_throw_error(env, NULL, "out of memory");
    return NULL;
  }
  m->addr = addr;
  m->len = (size_t)bytes;

  napi_value buf;
  if (napi_create_external_arraybuffer(env, addr, (size_t)bytes,
                                       finalize_map, m, &buf) != napi_ok) {
    munmap(addr, (size_t)bytes);
    free(m);
    napi_throw_error(env, NULL, "napi_create_external_arraybuffer failed");
    return NULL;
  }

  napi_value out, madeIt;
  napi_create_object(env, &out);
  napi_set_named_property(env, out, "buffer", buf);
  napi_get_boolean(env, created ? true : false, &madeIt);
  napi_set_named_property(env, out, "created", madeIt);
  return out;
}

// Returns zero or errno.
static napi_value Unlink(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value argv[1];
  napi_get_cb_info(env, info, &argc, argv, NULL, NULL);
  char name[NAME_MAX_LEN];
  size_t nlen = 0;
  if (argc < 1 || napi_get_value_string_utf8(env, argv[0], name, sizeof(name), &nlen) != napi_ok) {
    napi_throw_error(env, NULL, "unlink(name)");
    return NULL;
  }
  int rc = shm_unlink(name) == 0 ? 0 : errno;
  napi_value v;
  napi_create_int32(env, rc, &v);
  return v;
}

static napi_value Init(napi_env env, napi_value exports) {
  struct { const char *name; napi_callback fn; } fns[] = {
    { "open",   Open },
    { "unlink", Unlink },
  };
  for (unsigned i = 0; i < sizeof(fns) / sizeof(fns[0]); i++) {
    napi_value f;
    napi_create_function(env, fns[i].name, NAPI_AUTO_LENGTH, fns[i].fn, NULL, &f);
    napi_set_named_property(env, exports, fns[i].name, f);
  }
  return exports;
}

NAPI_MODULE(NODE_GYP_MODULE_NAME, Init)
