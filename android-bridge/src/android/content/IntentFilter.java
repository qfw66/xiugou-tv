package android.content;

import java.util.ArrayList;
import java.util.List;

public class IntentFilter {
    private final List<String> actions = new ArrayList<>();

    public IntentFilter() {
    }

    public IntentFilter(String action) {
        addAction(action);
    }

    public void addAction(String action) {
        if (action != null) actions.add(action);
    }

    public int countActions() {
        return actions.size();
    }

    public String getAction(int index) {
        return actions.get(index);
    }

    public boolean hasAction(String action) {
        return actions.contains(action);
    }

    public void setPriority(int priority) {
    }
}
