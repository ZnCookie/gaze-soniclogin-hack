// 把 soniclogin-helper 里 Gaze 读到的 PAM service 名从 "soniclogin" 伪造成 "sddm"，
// 从而命中 Gaze 0.5.2 的 is_kwallet_login 白名单，让钱包密码注入链路成立。
// 只拦截 pam_get_item(PAM_SERVICE=1)，其余 item（含 PAM_AUTHTOK=6）原样透传。
#define _GNU_SOURCE
#include <dlfcn.h>
#include <security/pam_appl.h>
#include <string.h>
#include <pthread.h>

typedef int (*pam_get_item_fn)(const pam_handle_t *, int, const void **);
static pam_get_item_fn real_pam_get_item = NULL;
static pthread_once_t once = PTHREAD_ONCE_INIT;

static void init_real(void) {
    real_pam_get_item = (pam_get_item_fn)dlsym(RTLD_NEXT, "pam_get_item");
}

int pam_get_item(const pam_handle_t *pamh, int item_type, const void **item) {
    pthread_once(&once, init_real);
    int ret = real_pam_get_item(pamh, item_type, item);

    // PAM_SERVICE == 1；PAM_SUCCESS == 0。全局伪造，不判断调用者，避免
    // __builtin_return_address 经过 PLT 落到 libpam/ld.so 导致判断失效。
    if (item_type == 1 && ret == 0 && item && *item) {
        if (strcmp((const char *)*item, "soniclogin") == 0) {
            *item = "sddm";
        }
    }
    return ret;
}
