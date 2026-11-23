pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import qs.modules.services

Singleton {
    id: root

    property bool running: false
    property string sessionId: ""
    property bool hasActiveSession: false
    property string currentStatus: "Idle"
    property string currentCommand: ""
    property int totalSteps: 0
    property int completedSteps: 0
    property real progress: totalSteps > 0 ? (completedSteps / totalSteps) : (running ? -1 : 0)
    property string streamingText: ""
    property string lastError: ""

    // Screenshot / Vision state
    property string pendingScreenshotPath: ""
    property bool capturingScreenshot: false
    property string screenshotError: ""
    property var _screenshotCallback: null
    property var _attachCallback: null
    property var _visionCallback: null

    property ListModel stepsModel: ListModel {}

    // Settings synced with ModsService
    property string gooseBinary: "goose"
    property string gooseMode: "auto"
    property string builtinExtensions: "developer"
    property int maxTurns: 25
    property bool defaultToGooseOnOpen: true
    property string screenshotMode: "monitor"
    property bool autoScreenshotOnPrompt: false
    property string visionModel: ""
    property string visionApiBase: "http://127.0.0.1:4000/v1"
    property string visionApiKey: ""

    signal textDelta(string chunk)
    signal runFinished(string finalText, bool success, string errorMessage)

    readonly property string iconPath: Qt.resolvedUrl("../../assets/icons/goose.svg").toString()
    readonly property string attachScriptPath: Qt.resolvedUrl("../../scripts/goose_save_attachments.py").toString().replace("file://", "")
    readonly property string visionScriptPath: Qt.resolvedUrl("../../scripts/goose_vision.py").toString().replace("file://", "")

    Connections {
        target: ModsService
        ignoreUnknownSignals: true
        function onSettingChanged(modId, key, value) {
            if (modId !== "community.goose.agent") return;
            root._applySetting(key, value);
        }
    }

    Component.onCompleted: {
        if (typeof ModsService === "undefined" || !ModsService || !ModsService.getSettings) return;
        ModsService.getSettings("community.goose.agent", function(settings, error) {
            if (error || !settings || !settings.values) return;
            const keys = [
                "gooseBinary", "gooseMode", "builtinExtensions", "maxTurns",
                "defaultToGooseOnOpen", "screenshotMode", "autoScreenshotOnPrompt",
                "visionModel", "visionApiBase", "visionApiKey"
            ];
            for (let i = 0; i < keys.length; i++) {
                const val = settings.values[keys[i]];
                if (val !== undefined) root._applySetting(keys[i], val);
            }
        });
    }

    function _applySetting(key, value) {
        if (key === "gooseBinary" && value) root.gooseBinary = String(value);
        else if (key === "gooseMode" && value) root.gooseMode = String(value);
        else if (key === "builtinExtensions" && value !== undefined) root.builtinExtensions = String(value);
        else if (key === "maxTurns" && value) root.maxTurns = Math.max(1, Number(value));
        else if (key === "defaultToGooseOnOpen") root.defaultToGooseOnOpen = Boolean(value);
        else if (key === "screenshotMode" && value) root.screenshotMode = String(value);
        else if (key === "autoScreenshotOnPrompt") root.autoScreenshotOnPrompt = Boolean(value);
        else if (key === "visionModel" && value !== undefined) root.visionModel = String(value).trim();
        else if (key === "visionApiBase" && value) root.visionApiBase = String(value).trim();
        else if (key === "visionApiKey" && value !== undefined) root.visionApiKey = String(value).trim();
    }

    function captureScreenshot(modeOverride, callback) {
        if (screenshotProc.running) return;
        const mode = modeOverride || root.screenshotMode || "monitor";
        root.capturingScreenshot = true;
        root.screenshotError = "";
        root._screenshotCallback = callback || null;
        screenshotProc.buffer = "";
        screenshotProc.command = ["python3", GooseContextService.screenshotScriptPath, mode];
        screenshotProc.running = true;
    }

    function clearScreenshot() {
        root.pendingScreenshotPath = "";
        root.screenshotError = "";
    }

    function resetSession() {
        stop();
        root.sessionId = "ambxst-" + Date.now();
        root.hasActiveSession = false;
        root.stepsModel.clear();
        root.totalSteps = 0;
        root.completedSteps = 0;
        root.currentCommand = "";
        root.currentStatus = "Idle";
        root.streamingText = "";
        root.lastError = "";
        root.pendingScreenshotPath = "";
        root.screenshotError = "";
    }

    function stop() {
        if (visionProc.running) visionProc.running = false;
        if (gooseProc.running) {
            gooseProc.signal(2);
            gooseProc.running = false;
        }
        root.running = false;
        root.currentStatus = "Stopped";
    }

    function _saveAttachments(attachments, callback) {
        if (!attachments || attachments.length === 0) {
            callback([]);
            return;
        }
        const tmpJson = "/tmp/ambxst-goose-pending-attachments.json";
        root._attachCallback = callback;
        attachFileView.path = tmpJson;
        attachFileView.setText(JSON.stringify(attachments));
        Qt.callLater(function() {
            attachProc.buffer = "";
            attachProc.command = ["python3", root.attachScriptPath, tmpJson];
            attachProc.running = true;
        });
    }

    function _analyzeImagesWithVisionModel(imagePaths, promptText, callback) {
        const tmpReq = "/tmp/ambxst-goose-vision-req.json";
        root._visionCallback = callback;
        root.currentStatus = "Analyzing image with " + root.visionModel + "...";
        visionReqFileView.path = tmpReq;
        visionReqFileView.setText(JSON.stringify({
            apiBase: root.visionApiBase,
            model: root.visionModel,
            apiKey: root.visionApiKey,
            prompt: promptText,
            images: imagePaths
        }));
        Qt.callLater(function() {
            visionProc.buffer = "";
            visionProc.command = ["python3", root.visionScriptPath, tmpReq];
            visionProc.running = true;
        });
    }

    function sendPrompt(promptText, attachments) {
        const hasAttachments = attachments && attachments.length > 0;
        const hasShot = root.pendingScreenshotPath && root.pendingScreenshotPath.length > 0;
        if ((!promptText || !promptText.trim()) && !hasAttachments && !hasShot) return;

        // Avoid launching overlapping requests against single-slot LiteLLM deployments
        if (root.running) {
            root.runFinished("", false, "Goose is still finishing the previous request. Wait or click Stop.");
            return;
        }

        if (!root.sessionId) {
            root.sessionId = "ambxst-" + Date.now();
        }

        const effectivePrompt = (promptText && promptText.trim())
            ? promptText.trim()
            : "Analyze the attached image(s).";

        root.stepsModel.clear();
        root.totalSteps = 0;
        root.completedSteps = 0;
        root.streamingText = "";
        root.lastError = "";
        root.currentCommand = "";
        root.running = true;

        const afterImagesReady = function(imagePaths) {
            root.currentStatus = "Capturing window context...";
            GooseContextService.captureSnapshot(function() {
                if (imagePaths.length > 0 && root.visionModel.length > 0) {
                    root._analyzeImagesWithVisionModel(imagePaths, effectivePrompt, function(ok, resultText) {
                        if (ok && resultText) {
                            const enriched = "[Vision analysis from " + root.visionModel + " for image(s) "
                                + imagePaths.join(", ") + "]:\n" + resultText + "\n\nUser request:\n" + effectivePrompt;
                            root._launchGoose(enriched, []);
                        } else {
                            // Fall back to direct image paths if dedicated vision model failed
                            root.screenshotError = resultText || "Vision model fallback failed";
                            root._launchGoose(effectivePrompt, imagePaths);
                        }
                    });
                } else {
                    root._launchGoose(effectivePrompt, imagePaths);
                }
            });
        };

        const collectAllImages = function() {
            root._saveAttachments(attachments || [], function(uploadedPaths) {
                const allPaths = [];
                if (root.pendingScreenshotPath && root.pendingScreenshotPath.length > 0) {
                    allPaths.push(root.pendingScreenshotPath);
                    root.pendingScreenshotPath = "";
                }
                for (let i = 0; i < uploadedPaths.length; i++) {
                    allPaths.push(uploadedPaths[i]);
                }
                afterImagesReady(allPaths);
            });
        };

        if (root.autoScreenshotOnPrompt && !hasShot && !hasAttachments) {
            root.currentStatus = "Capturing screenshot...";
            root.captureScreenshot(root.screenshotMode, function() {
                collectAllImages();
            });
        } else {
            collectAllImages();
        }
    }

    function _launchGoose(promptText, imagePaths) {
        const systemCtx = GooseContextService.buildSystemContext();
        const workDir = GooseContextService.primaryDirectory || Quickshell.env("HOME") || "/";

        let finalPrompt = promptText;
        if (imagePaths && imagePaths.length > 0) {
            // Put absolute paths clearly so Goose's detect_image_path() and read_image both work
            const pathLines = imagePaths.join("\n");
            finalPrompt = "Attached image file(s) — inspect using vision or developer__read_image:\n"
                + pathLines + "\n\n" + promptText;
        }

        const args = [
            root.gooseBinary,
            "run",
            "--name", root.sessionId,
            "--output-format", "stream-json",
            "--max-turns", String(root.maxTurns),
            "--system", systemCtx,
            "--text", finalPrompt
        ];

        if (root.hasActiveSession) {
            args.push("--resume");
        }
        if (root.builtinExtensions && root.builtinExtensions.trim().length > 0) {
            args.push("--with-builtin", root.builtinExtensions.trim());
        }

        gooseProc.workingDirectory = workDir;
        gooseProc.environment = ({
            "GOOSE_MODE": root.gooseMode
        });
        gooseProc.stderrBuffer = "";
        gooseProc.afterTool = false;
        gooseProc.command = args;
        root.currentStatus = "Thinking...";
        gooseProc.running = true;
    }

    function _formatToolSummary(name, argsObj) {
        if (!argsObj || typeof argsObj !== "object") return name;
        if (argsObj.command) return String(argsObj.command);
        if (argsObj.path && argsObj.command_type) return argsObj.command_type + " " + argsObj.path;
        if (argsObj.path) return name + ": " + argsObj.path;
        const keys = Object.keys(argsObj);
        if (keys.length === 0) return name;
        const preview = keys.slice(0, 2).map(k => k + "=" + JSON.stringify(argsObj[k])).join(" ");
        return name + " (" + preview + ")";
    }

    function _extractToolOutput(toolResult) {
        if (!toolResult || !toolResult.value || !toolResult.value.content) return "";
        const parts = toolResult.value.content;
        const out = [];
        for (let i = 0; i < parts.length; i++) {
            if (parts[i].type === "text" && parts[i].text) {
                out.push(parts[i].text);
            }
        }
        return out.join("\n").trim();
    }

    function _handleStreamLine(line) {
        const trimmed = line.trim();
        if (!trimmed || trimmed[0] !== "{") return;

        let event;
        try {
            event = JSON.parse(trimmed);
        } catch (e) {
            return;
        }

        if (event.type === "message" && event.message && Array.isArray(event.message.content)) {
            const role = event.message.role;
            const content = event.message.content;

            for (let i = 0; i < content.length; i++) {
                const part = content[i];

                if (part.type === "text" && part.text && role === "assistant") {
                    const chunk = gooseProc.afterTool ? ("\n\n" + part.text) : part.text;
                    gooseProc.afterTool = false;
                    Qt.callLater(function() {
                        root.streamingText += chunk;
                        root.currentStatus = "Responding...";
                        root.textDelta(chunk);
                    });
                } else if (part.type === "toolRequest") {
                    const call = (part.toolCall && part.toolCall.value) ? part.toolCall.value : {};
                    const toolName = call.name || "tool";
                    const summary = root._formatToolSummary(toolName, call.arguments || {});
                    const callId = String(part.id || ("step-" + Date.now()));

                    Qt.callLater(function() {
                        root.totalSteps += 1;
                        root.currentCommand = summary;
                        root.currentStatus = "Running " + toolName + "...";
                        root.stepsModel.append({
                            callId: callId,
                            toolName: toolName,
                            commandText: summary,
                            status: "running",
                            outputPreview: ""
                        });
                    });
                } else if (part.type === "toolResponse") {
                    const callId = String(part.id || "");
                    const isErr = !part.toolResult
                        || part.toolResult.status !== "success"
                        || (part.toolResult.value && part.toolResult.value.isError === true);
                    const outputText = root._extractToolOutput(part.toolResult);
                    gooseProc.afterTool = true;

                    Qt.callLater(function() {
                        root.completedSteps += 1;
                        for (let idx = 0; idx < root.stepsModel.count; idx++) {
                            if (root.stepsModel.get(idx).callId === callId) {
                                root.stepsModel.setProperty(idx, "status", isErr ? "error" : "done");
                                root.stepsModel.setProperty(idx, "outputPreview", outputText.slice(0, 400));
                                break;
                            }
                        }
                        root.currentStatus = "Analyzing result (" + root.completedSteps + "/" + root.totalSteps + ")...";
                    });
                }
            }
        } else if (event.type === "complete") {
            Qt.callLater(function() {
                root.currentStatus = "Completed";
                root.currentCommand = "";
            });
        }
    }

    FileView { id: attachFileView }
    FileView { id: visionReqFileView }

    Process {
        id: attachProc
        property string buffer: ""
        stdout: SplitParser { onRead: data => { attachProc.buffer += data + "\n"; } }
        onExited: (exitCode, exitStatus) => {
            Qt.callLater(function() {
                let paths = [];
                try {
                    const parsed = JSON.parse(attachProc.buffer.trim());
                    if (Array.isArray(parsed.paths)) paths = parsed.paths;
                } catch (e) {}
                if (root._attachCallback) {
                    const cb = root._attachCallback;
                    root._attachCallback = null;
                    cb(paths);
                }
            });
        }
    }

    Process {
        id: visionProc
        property string buffer: ""
        stdout: SplitParser { onRead: data => { visionProc.buffer += data + "\n"; } }
        onExited: (exitCode, exitStatus) => {
            Qt.callLater(function() {
                let ok = false;
                let text = "";
                try {
                    const parsed = JSON.parse(visionProc.buffer.trim());
                    if (parsed.ok) {
                        ok = true;
                        text = parsed.analysis || "";
                    } else {
                        text = parsed.error || "Vision model returned an error";
                    }
                } catch (e) {
                    text = "Vision helper exited with code " + exitCode;
                }
                if (root._visionCallback) {
                    const cb = root._visionCallback;
                    root._visionCallback = null;
                    cb(ok, text);
                }
            });
        }
    }

    Process {
        id: screenshotProc
        property string buffer: ""

        stdout: SplitParser {
            onRead: data => {
                screenshotProc.buffer += data + "\n";
            }
        }

        onExited: (exitCode, exitStatus) => {
            Qt.callLater(function() {
                root.capturingScreenshot = false;
                let ok = false;
                try {
                    const parsed = JSON.parse(screenshotProc.buffer.trim());
                    if (parsed.ok && parsed.path) {
                        root.pendingScreenshotPath = parsed.path;
                        root.screenshotError = "";
                        ok = true;
                    } else if (parsed.error) {
                        root.screenshotError = parsed.error;
                    }
                } catch (e) {
                    if (exitCode !== 0) {
                        root.screenshotError = "Screenshot failed (is grim installed?)";
                    }
                }
                if (root._screenshotCallback) {
                    const cb = root._screenshotCallback;
                    root._screenshotCallback = null;
                    cb(ok);
                }
            });
        }
    }

    Process {
        id: gooseProc
        property string stderrBuffer: ""
        property bool afterTool: false

        stdout: SplitParser {
            onRead: line => {
                root._handleStreamLine(line);
            }
        }

        stderr: SplitParser {
            onRead: line => {
                gooseProc.stderrBuffer = (gooseProc.stderrBuffer + "\n" + line).slice(-2000);
            }
        }

        onExited: (exitCode, exitStatus) => {
            Qt.callLater(function() {
                root.running = false;
                if (exitCode === 0) {
                    root.hasActiveSession = true;
                    root.currentStatus = "Done";
                    root.runFinished(root.streamingText, true, "");
                } else {
                    const errMsg = gooseProc.stderrBuffer.trim() || ("Goose exited with code " + exitCode);
                    root.lastError = errMsg;
                    root.currentStatus = "Error";
                    root.runFinished(root.streamingText, false, errMsg);
                }
            });
        }
    }
}
