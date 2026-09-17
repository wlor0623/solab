package zhou.kelivo.bootstrapdemo;

import android.content.Context;
import android.content.pm.PackageInfo;
import android.content.pm.PackageManager;
import android.content.pm.Signature;
import android.os.Parcel;
import android.os.Parcelable;

import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.security.MessageDigest;
import java.util.Map;

public final class DemoSignatureBridge {
    private static final String CERTIFICATE_ASSET = "bootstrap/original-cert.der";
    private static volatile String status = "not installed";

    private DemoSignatureBridge() {
    }

    public static synchronized void install(Context context) {
        try {
            Signature expected = new Signature(readAsset(context, CERTIFICATE_ASSET));
            enableHiddenApiAccess();
            Parcelable.Creator<PackageInfo> current = PackageInfo.CREATOR;
            if (!(current instanceof SignatureCreator)) {
                Field field = PackageInfo.class.getDeclaredField("CREATOR");
                field.setAccessible(true);
                field.set(null, new SignatureCreator(current, context.getPackageName(), expected));
                clearParcelCreators();
            }
            status = matches(context, expected) ? "passed" : "bridge installed, query mismatch";
        } catch (Throwable error) {
            status = "failed: " + error.getClass().getSimpleName();
        }
        BootstrapState.record("legacy signature: " + status);
    }

    public static String status() {
        return status;
    }

    private static boolean matches(Context context, Signature expected) throws Exception {
        PackageInfo info = context.getPackageManager().getPackageInfo(
                context.getPackageName(), PackageManager.GET_SIGNATURES);
        return info.signatures != null
                && info.signatures.length == 1
                && sha256(info.signatures[0].toByteArray()).equals(sha256(expected.toByteArray()));
    }

    private static byte[] readAsset(Context context, String name) throws Exception {
        try (InputStream input = context.getAssets().open(name);
             ByteArrayOutputStream output = new ByteArrayOutputStream()) {
            byte[] buffer = new byte[4096];
            int count;
            while ((count = input.read(buffer)) != -1) {
                output.write(buffer, 0, count);
            }
            return output.toByteArray();
        }
    }

    private static void enableHiddenApiAccess() {
        try {
            Method forName = Class.class.getDeclaredMethod("forName", String.class);
            Method getMethod = Class.class.getDeclaredMethod(
                    "getDeclaredMethod", String.class, Class[].class);
            Class<?> runtimeClass = (Class<?>) forName.invoke(null, "dalvik.system.VMRuntime");
            Method getRuntime = (Method) getMethod.invoke(runtimeClass, "getRuntime", null);
            Object runtime = getRuntime.invoke(null);
            Method exemptions = (Method) getMethod.invoke(
                    runtimeClass, "setHiddenApiExemptions", new Class[]{String[].class});
            exemptions.invoke(runtime, (Object) new String[]{"Landroid/"});
        } catch (Throwable ignored) {
        }
    }

    private static void clearParcelCreators() {
        clearStaticMap("mCreators");
        clearStaticMap("sPairedCreators");
    }

    private static void clearStaticMap(String fieldName) {
        try {
            Field field = Parcel.class.getDeclaredField(fieldName);
            field.setAccessible(true);
            Object value = field.get(null);
            if (value instanceof Map) {
                ((Map<?, ?>) value).clear();
            }
        } catch (Throwable ignored) {
        }
    }

    private static String sha256(byte[] bytes) throws Exception {
        StringBuilder value = new StringBuilder();
        for (byte item : MessageDigest.getInstance("SHA-256").digest(bytes)) {
            value.append(String.format("%02x", item & 0xff));
        }
        return value.toString();
    }

    private static final class SignatureCreator implements Parcelable.Creator<PackageInfo> {
        private final Parcelable.Creator<PackageInfo> delegate;
        private final String packageName;
        private final Signature expected;

        SignatureCreator(
                Parcelable.Creator<PackageInfo> delegate,
                String packageName,
                Signature expected
        ) {
            this.delegate = delegate;
            this.packageName = packageName;
            this.expected = expected;
        }

        @Override
        public PackageInfo createFromParcel(Parcel source) {
            PackageInfo info = delegate.createFromParcel(source);
            if (packageName.equals(info.packageName)) {
                info.signatures = new Signature[]{expected};
            }
            return info;
        }

        @Override
        public PackageInfo[] newArray(int size) {
            return delegate.newArray(size);
        }
    }
}
