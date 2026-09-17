package zhou.kelivo.bootstrapdemo;

import android.app.Activity;
import android.os.Bundle;
import android.widget.TextView;

public final class MainActivity extends Activity {
    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        BootstrapState.record("activity");
        TextView view = new TextView(this);
        view.setPadding(48, 64, 48, 64);
        view.setTextSize(16);
        view.setText(
                "Kelivo 自研启动 Demo\n\n"
                        + "启动顺序: " + String.join(" → ", BootstrapState.snapshot()) + "\n\n"
                        + "内嵌载荷 SHA-256: " + BootstrapPayload.sha256() + "\n\n"
                        + "Native: " + NativeProbe.status() + "\n\n"
                        + "旧式签名校验: " + DemoSignatureBridge.status() + "\n\n"
                        + "Android 9 及以上会先显示 component factory。"
        );
        setContentView(view);
    }
}
