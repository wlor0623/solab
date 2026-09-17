package zhou.solab.blutter;

import android.os.ParcelFileDescriptor;
import zhou.solab.blutter.IBlutterRunnerCallback;

interface IBlutterRunner {
    String getManifestJson();
    void run(String jobId, String libraryName, in ParcelFileDescriptor libapp, in ParcelFileDescriptor libflutter, in ParcelFileDescriptor result, String optionsJson, IBlutterRunnerCallback callback);
    void cancel(String jobId);
}
