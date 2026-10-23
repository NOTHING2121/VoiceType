/// Executes the same reconnect decisions in the menu model and deterministic tests.
/// No lifecycle is duplicated here: facts come from the system listener and the session reducer.
public enum HotkeyConnectionPolicy {
    public static func refresh(trusted: Bool, installed: Bool, automatically: Bool,
                               install: () -> Void, uninstall: () -> Void) {
        if !trusted { uninstall() }
        else if !installed && automatically { install() }
    }

    public static func restart(isIdle: Bool, install: () -> Void) {
        if isIdle { install() }
    }
}
