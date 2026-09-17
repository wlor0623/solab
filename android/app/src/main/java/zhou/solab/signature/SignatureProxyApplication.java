package zhou.solab.signature;

import android.app.Application;
import android.content.Context;

public class SignatureProxyApplication extends Application {
    @Override
    protected void attachBaseContext(Context base) {
        SignatureBypass.install(base);
        super.attachBaseContext(base);
    }
}
