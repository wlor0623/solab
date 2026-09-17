package zhou.kelivo.bootstrapdemo;

public final class NativeProbe {
    private static final String status;

    static {
        String value;
        try {
            System.loadLibrary("kelivo_bootstrap_demo");
            value = nativeVersion();
        } catch (Throwable error) {
            value = "native unavailable: " + error.getClass().getSimpleName();
        }
        status = value;
    }

    private NativeProbe() {
    }

    public static String status() {
        return status;
    }

    private static native String nativeVersion();
}
