package zhou.kelivo.bootstrapdemo;

import java.util.ArrayList;
import java.util.Collections;
import java.util.List;

public final class BootstrapState {
    private static final List<String> events = new ArrayList<>();

    private BootstrapState() {
    }

    public static synchronized void record(String event) {
        events.add(event);
    }

    public static synchronized List<String> snapshot() {
        return Collections.unmodifiableList(new ArrayList<>(events));
    }
}
