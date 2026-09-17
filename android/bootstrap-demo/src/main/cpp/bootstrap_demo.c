#include <jni.h>

JNIEXPORT jstring JNICALL
Java_zhou_kelivo_bootstrapdemo_NativeProbe_nativeVersion(
        JNIEnv *env,
        jclass clazz) {
    (void) clazz;
    return (*env)->NewStringUTF(env, "Kelivo native bootstrap 1.0");
}
