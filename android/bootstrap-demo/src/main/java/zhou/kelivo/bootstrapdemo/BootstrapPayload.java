package zhou.kelivo.bootstrapdemo;

import android.content.Context;

import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.security.MessageDigest;

public final class BootstrapPayload {
    private static final String ASSET_NAME = "bootstrap/payload.txt";
    private static volatile String payloadSha256 = "not prepared";

    private BootstrapPayload() {
    }

    public static synchronized void prepare(Context context) {
        try {
            File directory = new File(context.getFilesDir(), "kelivo-bootstrap");
            if (!directory.isDirectory() && !directory.mkdirs()) {
                throw new IllegalStateException("cannot create payload directory");
            }
            File output = new File(directory, "payload.txt");
            File temporary = new File(directory, "payload.tmp");
            try (InputStream input = context.getAssets().open(ASSET_NAME);
                 FileOutputStream stream = new FileOutputStream(temporary)) {
                byte[] buffer = new byte[8192];
                int count;
                while ((count = input.read(buffer)) != -1) {
                    stream.write(buffer, 0, count);
                }
            }
            String expected = sha256(temporary);
            if (output.isFile() && expected.equals(sha256(output))) {
                temporary.delete();
            } else if (!temporary.renameTo(output)) {
                temporary.delete();
                throw new IllegalStateException("cannot publish payload");
            }
            payloadSha256 = expected;
            BootstrapState.record("payload verified");
        } catch (Throwable error) {
            payloadSha256 = "failed: " + error.getClass().getSimpleName();
            BootstrapState.record("payload failed");
        }
    }

    public static String sha256() {
        return payloadSha256;
    }

    private static String sha256(File file) throws Exception {
        MessageDigest digest = MessageDigest.getInstance("SHA-256");
        try (InputStream input = new FileInputStream(file)) {
            byte[] buffer = new byte[8192];
            int count;
            while ((count = input.read(buffer)) != -1) {
                digest.update(buffer, 0, count);
            }
        }
        StringBuilder value = new StringBuilder();
        for (byte item : digest.digest()) {
            value.append(String.format("%02x", item & 0xff));
        }
        return value.toString();
    }
}
