package zhou.solab.signature;

import android.content.Context;
import android.content.pm.PackageInfo;
import android.content.pm.PackageManager;
import android.content.pm.Signature;
import android.os.Parcel;
import android.os.Parcelable;
import android.util.Base64;
import android.util.Log;

import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.security.MessageDigest;
import java.util.Map;

public final class SignatureBypass {
    private static final String TAG = "SolabSignatureBypass";
    private static final String CONFIG_ASSET = "solab/signature-bypass.json";
    private static final String ORIGINAL_APK_ASSET = "solab/original.apk";
    private static volatile boolean installed;
    private static volatile String originalApkPath;

    private SignatureBypass() {
    }

    public static synchronized void install(Context context) {
        if (installed) {
            return;
        }
        // 去签初始化失败绝不能阻断目标应用启动：任何一步失败都降级为「去签不生效」，
        // 而不是抛异常让 Application 无法实例化（那会让「去签」本身变成崩溃源）。
        String mode = "unknown";
        try {
            JSONObject config = new JSONObject(readAsset(context, CONFIG_ASSET));
            String packageName = config.getString("packageName");
            Signature signature = new Signature(Base64.decode(
                    config.getString("signatureBase64"), Base64.DEFAULT));
            mode = config.optString("mode", "normal");
            if ("original_apk".equals(mode)) {
                try {
                    originalApkPath = extractOriginalApk(
                            context, config.getString("sourceSha256"));
                    installNativeHook(context);
                } catch (Throwable error) {
                    // 原包提取或 native hook 失败时，退化为仅伪造 PackageInfo 签名
                    originalApkPath = null;
                    Log.w(TAG, "original_apk native layer degraded: " + error);
                }
            }
            exemptHiddenApis();
            installPackageInfoCreator(packageName, signature);
        } catch (Throwable error) {
            // 配置读取等前置失败同样不阻断启动
            Log.w(TAG, "signature bypass disabled: " + error);
        }
        installed = true;
        Log.i(TAG, "installed, mode=" + mode
                + ", originalApkPath=" + originalApkPath);
    }

    /**
     * 内联 LSPosed HiddenApiBypass 的「双反射」手法，豁免 Android 的 hidden API
     * 访问限制。否则 Android 9+ 上对 PackageInfo.CREATOR 这类 public static final
     * 字段、以及 PackageManager.sPackageInfoCache / Parcel.mCreators 这些 @hide 字段
     * 的反射写入会被拒绝，导致签名伪造失效。
     */
    private static void exemptHiddenApis() {
        try {
            Method forName = Class.class.getDeclaredMethod("forName", String.class);
            Method getDeclaredMethod = Class.class.getDeclaredMethod(
                    "getDeclaredMethod", String.class, Class[].class);
            Class<?> vmRuntimeClass = (Class<?>) forName.invoke(null, "dalvik.system.VMRuntime");
            Method getRuntime = (Method) getDeclaredMethod.invoke(vmRuntimeClass, "getRuntime", null);
            Method setHiddenApiExemptions = (Method) getDeclaredMethod.invoke(
                    vmRuntimeClass, "setHiddenApiExemptions", new Class[]{String[].class});
            Object runtime = getRuntime.invoke(null);
            setHiddenApiExemptions.invoke(runtime, (Object) new String[]{
                    "Landroid/", "Lcom/android/", "Ljava/lang/"
            });
        } catch (Throwable error) {
            Log.w(TAG, "hidden api exemption failed: " + error);
        }
    }

    /** native hook 入口：把读取 base.apk 的路径替换为原包路径（原包模式）。 */
    private static native void hookApkPath(String apkPath, String repPath);

    /**
     * 原包模式第二层：加载注入的 libsolab_signature.so 并 hook open/openat，
     * 使直接读 META-INF 证书的签名校验也拿到原始签名（对齐 ApkSignatureKillerEx 的 killOpen）。
     * 任何失败都静默降级，绝不阻断启动。
     */
    private static void installNativeHook(Context context) {
        if (originalApkPath == null) return;
        try {
            String realApkPath = context.getApplicationInfo().sourceDir;
            if (realApkPath == null || realApkPath.isEmpty()) return;
            System.loadLibrary("solab_signature");
            hookApkPath(realApkPath, originalApkPath);
        } catch (Throwable error) {
            Log.w(TAG, "native hook install failed: " + error);
        }
    }

    /** 反射替换 PackageInfo.CREATOR，每步独立降级，失败不崩溃。 */
    private static void installPackageInfoCreator(String packageName, Signature signature) {
        try {
            Parcelable.Creator<PackageInfo> creator = PackageInfo.CREATOR;
            if (creator instanceof PackageInfoCreator) {
                return;
            }
            Field field = findField(PackageInfo.class, "CREATOR");
            field.set(null, new PackageInfoCreator(creator, packageName, signature));
        } catch (Throwable error) {
            Log.w(TAG, "PackageInfo.CREATOR replace failed: " + error);
            return;
        }
        clearStaticMap(Parcel.class, "mCreators");
        clearStaticMap(Parcel.class, "sPairedCreators");
        clearStaticObject(PackageManager.class, "sPackageInfoCache");
        try {
            findField(Class.class, "name").set(
                    PackageInfoCreator.class, "android.content.pm.PackageInfo$1");
        } catch (Throwable error) {
            Log.w(TAG, "PackageInfo creator identity update failed: " + error);
        }
    }

    private static String extractOriginalApk(Context context, String expectedSha256) throws Exception {
        File directory = new File(context.getFilesDir(), "solab");
        if (!directory.isDirectory() && !directory.mkdirs()) {
            throw new IllegalStateException("Cannot create original APK directory");
        }
        File output = new File(directory, "original.apk");
        // 缓存命中走 sidecar 标记，避免每次启动全文件读算 hash（大包首启会拖到 ANR 边缘）。
        // 标记内容 = 已校验的 sourceSha256；config 变化（换原包）时自然失配走重提取。
        File verified = new File(directory, "original.apk.ok");
        if (output.isFile() && verified.isFile()
                && expectedSha256.equals(readText(verified))) {
            return output.getAbsolutePath();
        }
        File temporary = new File(directory, "original.apk.tmp");
        if (temporary.exists() && !temporary.delete()) {
            throw new IllegalStateException("Cannot clear temporary original APK");
        }
        try (InputStream input = context.getAssets().open(ORIGINAL_APK_ASSET);
             FileOutputStream stream = new FileOutputStream(temporary)) {
            byte[] buffer = new byte[128 * 1024];
            int count;
            while ((count = input.read(buffer)) != -1) {
                stream.write(buffer, 0, count);
            }
        }
        if (!expectedSha256.equals(sha256(temporary))) {
            temporary.delete();
            throw new IllegalStateException("Embedded original APK hash mismatch");
        }
        if (output.exists() && !output.delete()) {
            temporary.delete();
            throw new IllegalStateException("Cannot replace cached original APK");
        }
        if (!temporary.renameTo(output)) {
            temporary.delete();
            throw new IllegalStateException("Cannot publish cached original APK");
        }
        try (FileOutputStream stream = new FileOutputStream(verified)) {
            stream.write(expectedSha256.getBytes("UTF-8"));
        }
        return output.getAbsolutePath();
    }

    private static String readText(File file) throws Exception {
        try (InputStream input = new java.io.FileInputStream(file);
             ByteArrayOutputStream output = new ByteArrayOutputStream()) {
            byte[] buffer = new byte[128];
            int count;
            while ((count = input.read(buffer)) != -1) {
                output.write(buffer, 0, count);
            }
            return output.toString("UTF-8");
        }
    }

    private static String sha256(File file) throws Exception {
        MessageDigest digest = MessageDigest.getInstance("SHA-256");
        try (InputStream input = new java.io.FileInputStream(file)) {
            byte[] buffer = new byte[128 * 1024];
            int count;
            while ((count = input.read(buffer)) != -1) {
                digest.update(buffer, 0, count);
            }
        }
        StringBuilder hex = new StringBuilder();
        for (byte value : digest.digest()) {
            hex.append(String.format("%02x", value & 0xff));
        }
        return hex.toString();
    }

    private static String readAsset(Context context, String name) throws Exception {
        try (InputStream input = context.getAssets().open(name);
             ByteArrayOutputStream output = new ByteArrayOutputStream()) {
            byte[] buffer = new byte[8192];
            int count;
            while ((count = input.read(buffer)) != -1) {
                output.write(buffer, 0, count);
            }
            return output.toString("UTF-8");
        }
    }

    private static Field findField(Class<?> type, String name) throws Exception {
        Class<?> current = type;
        while (current != null && current != Object.class) {
            try {
                Field field = current.getDeclaredField(name);
                field.setAccessible(true);
                return field;
            } catch (NoSuchFieldException ignored) {
                current = current.getSuperclass();
            }
        }
        throw new NoSuchFieldException(type.getName() + "." + name);
    }

    private static void clearStaticMap(Class<?> type, String name) {
        try {
            Object value = findField(type, name).get(null);
            if (value instanceof Map) {
                ((Map<?, ?>) value).clear();
            }
        } catch (Throwable ignored) {
        }
    }

    private static void clearStaticObject(Class<?> type, String name) {
        try {
            Object value = findField(type, name).get(null);
            if (value != null) {
                value.getClass().getMethod("clear").invoke(value);
            }
        } catch (Throwable ignored) {
        }
    }
}
