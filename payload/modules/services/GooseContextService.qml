pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import qs.modules.globals
import qs.modules.services

Singleton {
    id: root

    property var activeWorkspace: ({ id: "", name: "", monitor: "" })
    property var focusedWindow: null
    property string primaryDirectory: ""
    property var activeWorkspaceWindows: []
    property var openWindows: []
    property bool capturing: false
    property bool includeAllWindows: true
    property int pollIntervalSec: 2
    property string summaryLabel: ""
    property int windowCount: 0
    property int activeWorkspaceWindowCount: 0
    property var _pendingCallback: null
    property double _captureStartedAt: 0

    readonly property string scriptPath: Qt.resolvedUrl("../../scripts/goose_context.py").toString().replace("file://", "")
    readonly property string screenshotScriptPath: Qt.resolvedUrl("../../scripts/goose_screenshot.py").toString().replace("file://", "")

    Connections {
        target: ModsService
        ignoreUnknownSignals: true
        function onSettingChanged(modId, key, value) {
            if (modId !== "community.goose.agent") return;
            if (key === "includeAllWindows") root.includeAllWindows = Boolean(value);
            else if (key === "contextPollIntervalSec" && value) root.pollIntervalSec = Math.max(1, Number(value));
        }
    }

    // React immediately when the user switches workspaces, monitors, or windows
    Connections {
        target: typeof AxctlService !== "undefined" ? AxctlService : null
        ignoreUnknownSignals: true
        function onActiveWorkspaceChanged() { root.scheduleRefresh(); }
        function onFocusedWorkspaceChanged() { root.scheduleRefresh(); }
        function onWorkspacesChanged() { root.scheduleRefresh(); }
        function onActiveWindowChanged() { root.scheduleRefresh(); }
        function onFocusedWindowChanged() { root.scheduleRefresh(); }
        function onFocusedMonitorChanged() { root.scheduleRefresh(); }
        function onWindowsChanged() { root.scheduleRefresh(); }
    }

    Connections {
        target: typeof GlobalStates !== "undefined" ? GlobalStates : null
        ignoreUnknownSignals: true
        function onAssistantVisibleChanged() {
            if (GlobalStates.assistantVisible) {
                root.captureSnapshot();
            }
        }
    }

    Component.onCompleted: {
        if (typeof ModsService !== "undefined" && ModsService && ModsService.getSettings) {
            ModsService.getSettings("community.goose.agent", function(settings, error) {
                if (error || !settings || !settings.values) return;
                if (settings.values.includeAllWindows !== undefined) {
                    root.includeAllWindows = Boolean(settings.values.includeAllWindows);
                }
                if (settings.values.contextPollIntervalSec !== undefined) {
                    root.pollIntervalSec = Math.max(1, Number(settings.values.contextPollIntervalSec));
                }
            });
        }
    }

    // Debounce bursty compositor IPC signals (e.g. workspace switch + focus change)
    Timer {
        id: debounceTimer
        interval: 150
        repeat: false
        onTriggered: {
            if (typeof GlobalStates !== "undefined" && GlobalStates.assistantVisible) {
                root.captureSnapshot();
            }
        }
    }

    // Continuous background poll while AI Sidebar is open (catches cd/folder navigation inside terminals/file managers)
    Timer {
        id: contextPollTimer
        interval: Math.max(1, root.pollIntervalSec) * 1000
        repeat: true
        triggeredOnStart: true
        running: typeof GlobalStates !== "undefined" && GlobalStates.assistantVisible
        onTriggered: root.captureSnapshot()
    }

    function scheduleRefresh() {
        if (typeof GlobalStates !== "undefined" && GlobalStates.assistantVisible) {
            debounceTimer.restart();
        }
    }

    function captureSnapshot(callback) {
        const now = Date.now();
        if (contextProc.running) {
            if (now - root._captureStartedAt > 4000) {
                contextProc.running = false;
            } else {
                if (callback) root._pendingCallback = callback;
                return;
            }
        }
        root._pendingCallback = callback || null;
        root.capturing = true;
        root._captureStartedAt = now;
        contextProc.buffer = "";
        contextProc.command = root.includeAllWindows
            ? ["python3", root.scriptPath]
            : ["python3", root.scriptPath, "--focused-only"];
        contextProc.running = true;
    }

    function buildSystemContext() {
        const wsName = (root.activeWorkspace && root.activeWorkspace.name) ? root.activeWorkspace.name : "?";
        const monName = (root.activeWorkspace && root.activeWorkspace.monitor) ? (" on " + root.activeWorkspace.monitor) : "";

        const lines = [
            "You are running natively inside the Ambxst desktop shell on Wayland.",
            "The user invoked you directly from their desktop with SUPER+A.",
            "Use the live active-workspace window and open folder context below without asking the user to repeat paths they already have open.",
            "",
            "## Current Workspace: WS " + wsName + monName
        ];

        if (root.focusedWindow && root.focusedWindow.app) {
            lines.push("- Focused Application: " + root.focusedWindow.app);
            lines.push("- Window Title: " + (root.focusedWindow.title || "(untitled)"));
            if (root.focusedWindow.resolvedDir) {
                lines.push("- Resolved Directory: " + root.focusedWindow.resolvedDir);
            }
        } else {
            lines.push("- No open windows on this workspace.");
        }

        if (root.primaryDirectory) {
            lines.push("- Active Working Directory: " + root.primaryDirectory);
        }

        if (root.activeWorkspaceWindows && root.activeWorkspaceWindows.length > 0) {
            lines.push("");
            lines.push("## Windows on Current Workspace (WS " + wsName + ")");
            for (let i = 0; i < root.activeWorkspaceWindows.length; i++) {
                const w = root.activeWorkspaceWindows[i];
                let desc = "- " + (w.app || "unknown") + ": \"" + (w.title || "") + "\"";
                if (w.resolvedDir) desc += " (dir: " + w.resolvedDir + ")";
                if (w.focused) desc += " [FOCUSED]";
                lines.push(desc);
            }
        }

        if (root.openWindows && root.openWindows.length > 0) {
            const others = root.openWindows.filter(w => !w.onActiveWorkspace);
            if (others.length > 0) {
                lines.push("");
                lines.push("## Other Open Windows (Other Workspaces / Monitors)");
                for (let i = 0; i < others.length; i++) {
                    const w = others[i];
                    let desc = "- [WS " + (w.workspace || "?") + (w.onVisibleWorkspace ? ", VISIBLE" : "") + "] "
                        + (w.app || "unknown") + ": \"" + (w.title || "") + "\"";
                    if (w.resolvedDir) desc += " (dir: " + w.resolvedDir + ")";
                    lines.push(desc);
                }
            }
        }

        lines.push("");
        lines.push("## Vision & Screenshots");
        lines.push("If the user attaches a screenshot path, inspect it directly using your vision capability or the `read_image` tool.");
        lines.push("If the user asks you to look at their screen, inspect a UI/error, or take a screenshot yourself, run:");
        lines.push("  python3 " + root.screenshotScriptPath + " monitor");
        lines.push("(use `window` for just the active window or `all` for all monitors), read the returned `path` from the JSON output, and call `read_image` on that file path to analyze it.");
        lines.push("");
        lines.push("When performing file operations, operate inside the active workspace's resolved directory unless told otherwise, and concisely summarize what you changed.");
        return lines.join("\n");
    }

    Process {
        id: contextProc
        property string buffer: ""

        stdout: SplitParser {
            onRead: data => {
                contextProc.buffer += data + "\n";
            }
        }

        onExited: (exitCode, exitStatus) => {
            root.capturing = false;
            if (exitCode === 0 && contextProc.buffer.trim().length > 0) {
                try {
                    const parsed = JSON.parse(contextProc.buffer.trim());
                    Qt.callLater(function() {
                        const ws = parsed.activeWorkspace || { id: "", name: "", monitor: "" };
                        root.activeWorkspace = ws;
                        root.focusedWindow = parsed.focusedWindow || null;
                        root.primaryDirectory = parsed.primaryDirectory || "";
                        root.activeWorkspaceWindows = parsed.activeWorkspaceWindows || [];
                        root.openWindows = parsed.openWindows || [];
                        root.activeWorkspaceWindowCount = root.activeWorkspaceWindows.length;
                        root.windowCount = root.openWindows.length;

                        const wsPrefix = ws.name ? ("WS " + ws.name + " · ") : "";

                        if (root.focusedWindow && root.focusedWindow.resolvedDir) {
                            const home = Quickshell.env("HOME") || "";
                            const shortDir = home && root.focusedWindow.resolvedDir.startsWith(home)
                                ? "~" + root.focusedWindow.resolvedDir.slice(home.length)
                                : root.focusedWindow.resolvedDir;
                            root.summaryLabel = wsPrefix + (root.focusedWindow.app || "Folder") + " · " + shortDir;
                        } else if (root.focusedWindow && root.focusedWindow.title) {
                            root.summaryLabel = wsPrefix + root.focusedWindow.app + " · " + root.focusedWindow.title;
                        } else if (ws.name) {
                            root.summaryLabel = "WS " + ws.name + " · Empty workspace";
                        } else {
                            root.summaryLabel = root.windowCount + " open windows";
                        }

                        if (root._pendingCallback) {
                            const cb = root._pendingCallback;
                            root._pendingCallback = null;
                            cb();
                        }
                    });
                    return;
                } catch (e) {
                    console.warn("GooseContextService: JSON parse error:", e);
                }
            }
            if (root._pendingCallback) {
                const cb = root._pendingCallback;
                root._pendingCallback = null;
                cb();
            }
        }
    }
}
