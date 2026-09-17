package zhou.kelivo.bootstrapdemo;

import android.app.AppComponentFactory;
import android.app.Application;

public final class BootstrapFactory extends AppComponentFactory {
    @Override
    public Application instantiateApplication(
            ClassLoader classLoader,
            String className
    ) throws InstantiationException, IllegalAccessException, ClassNotFoundException {
        BootstrapState.record("component factory");
        BootstrapState.record("native: " + NativeProbe.status());
        return super.instantiateApplication(classLoader, className);
    }
}
