// SoLab 签名兼容注入的原生层（原包模式）。
//
// 移植自 ApkSignatureKillerEx（https://github.com/L-JINBIN/ApkSignatureKillerEx），
// 基于爱奇艺 xHook 实现 open/openat 系列符号的 PLT hook：
// 目标应用读取自身 base.apk 时，把路径替换为嵌入的原包路径，
// 使直接读 META-INF/*.RSA 证书的签名校验也拿到原始签名。
#include <jni.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <dlfcn.h>
#include <malloc.h>
#include <stdio.h>
#include <unistd.h>
#include <dirent.h>
#include <stdbool.h>
#include <string.h>
#include "xhook.h"
#include "xh_log.h"

// 使用堆副本而非 GetStringUTFChars 直持指针：
// 1) JNI 原始指针在 Release 前必须由本线程释放，跨调用持有既不安全也泄漏；
// 2) 重复调用 hookApkPath 时先释放旧值，避免旧路径悬空。
static char *apkPath__;
static char *repPath__;

int (*old_open)(const char *, int, mode_t);
static int openImpl(const char *pathname, int flags, mode_t mode) {
    if (apkPath__ != NULL && strcmp(pathname, apkPath__) == 0) {
        return old_open(repPath__, flags, mode);
    }
    return old_open(pathname, flags, mode);
}

int (*old_open64)(const char *, int, mode_t);
static int open64Impl(const char *pathname, int flags, mode_t mode) {
    if (apkPath__ != NULL && strcmp(pathname, apkPath__) == 0) {
        return old_open64(repPath__, flags, mode);
    }
    return old_open64(pathname, flags, mode);
}

int (*old_openat)(int, const char*, int, mode_t);
static int openatImpl(int fd, const char *pathname, int flags, mode_t mode) {
    if (apkPath__ != NULL && strcmp(pathname, apkPath__) == 0) {
        return old_openat(fd, repPath__, flags, mode);
    }
    return old_openat(fd, pathname, flags, mode);
}

int (*old_openat64)(int, const char*, int, mode_t);
static int openat64Impl(int fd, const char *pathname, int flags, mode_t mode) {
    if (apkPath__ != NULL && strcmp(pathname, apkPath__) == 0) {
        return old_openat64(fd, repPath__, flags, mode);
    }
    return old_openat64(fd, pathname, flags, mode);
}

FILE *(*old_fopen)(const char *, const char *);
static FILE *fopenImpl(const char *pathname, const char *mode) {
    if (apkPath__ != NULL && strcmp(pathname, apkPath__) == 0) {
        return old_fopen(repPath__, mode);
    }
    return old_fopen(pathname, mode);
}

FILE *(*old_fopen64)(const char *, const char *);
static FILE *fopen64Impl(const char *pathname, const char *mode) {
    if (apkPath__ != NULL && strcmp(pathname, apkPath__) == 0) {
        return old_fopen64(repPath__, mode);
    }
    return old_fopen64(pathname, mode);
}

void *(*old_dlopen)(const char *, int);
static void *dlopenImpl(const char *filename, int flags) {
    void *result = old_dlopen(filename, flags);
    if (result != NULL) {
        xhook_refresh(1);
    }
    return result;
}

void *(*old_android_dlopen_ext)(const char *, int, const void *);
static void *androidDlopenExtImpl(const char *filename, int flags, const void *extinfo) {
    void *result = old_android_dlopen_ext(filename, flags, extinfo);
    if (result != NULL) {
        xhook_refresh(1);
    }
    return result;
}

JNIEXPORT void JNICALL
Java_zhou_solab_signature_SignatureBypass_hookApkPath(JNIEnv *env, __attribute__((unused)) jclass clazz, jstring apkPath, jstring repPath) {
    if (apkPath == NULL || repPath == NULL) {
        XH_LOG_ERROR("hookApkPath: null argument, skip");
        return;
    }
    const char *apk = (*env)->GetStringUTFChars(env, apkPath, 0);
    const char *rep = (*env)->GetStringUTFChars(env, repPath, 0);
    if (apk == NULL || rep == NULL) {
        if (apk != NULL) (*env)->ReleaseStringUTFChars(env, apkPath, apk);
        if (rep != NULL) (*env)->ReleaseStringUTFChars(env, repPath, rep);
        XH_LOG_ERROR("hookApkPath: GetStringUTFChars failed, skip");
        return;
    }
    free(apkPath__);
    free(repPath__);
    apkPath__ = strdup(apk);
    repPath__ = strdup(rep);
    (*env)->ReleaseStringUTFChars(env, apkPath, apk);
    (*env)->ReleaseStringUTFChars(env, repPath, rep);

    xhook_register(".*\\.so$", "openat64", openat64Impl, (void **) &old_openat64);
    xhook_register(".*\\.so$", "openat", openatImpl, (void **) &old_openat);
    xhook_register(".*\\.so$", "open64", open64Impl, (void **) &old_open64);
    xhook_register(".*\\.so$", "open", openImpl, (void **) &old_open);
    xhook_register(".*\\.so$", "fopen64", fopen64Impl, (void **) &old_fopen64);
    xhook_register(".*\\.so$", "fopen", fopenImpl, (void **) &old_fopen);
    xhook_register(".*\\.so$", "dlopen", dlopenImpl, (void **) &old_dlopen);
    xhook_register(
        ".*\\.so$",
        "android_dlopen_ext",
        androidDlopenExtImpl,
        (void **) &old_android_dlopen_ext);

    xhook_refresh(0);
    XH_LOG_ERROR("hook installed: %s -> %s", apkPath__, repPath__);
}
