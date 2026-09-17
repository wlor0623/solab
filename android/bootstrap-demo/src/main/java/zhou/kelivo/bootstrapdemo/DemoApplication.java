package zhou.kelivo.bootstrapdemo;

import android.app.Application;

public final class DemoApplication extends Application {
    @Override
    public void onCreate() {
        BootstrapState.record("application");
        BootstrapPayload.prepare(this);
        DemoSignatureBridge.install(this);
        super.onCreate();
    }
}
