# Changelog

## 1.2.0

- Screenshot capture for Goose vision: "Shot" button in the sidebar, optional auto-attach on every prompt, and focused monitor / active window / all monitors modes (grim, with a spectacle fallback).
- Image attachments added in the AI sidebar are decoded and passed to Goose.
- Optional dedicated vision model: screenshots and uploads are analyzed through an OpenAI-compatible endpoint first, so text-only Goose models still get vision. Falls back to passing the image paths to Goose if the vision call fails.
- New settings for screenshots and the vision endpoint (screenshotMode, autoScreenshotOnPrompt, visionModel, visionApiBase, visionApiKey).
- Package metadata for public distribution: author, homepage, language declaration, README, license and CI validation.

## 1.0.0

- Native Goose autonomous agent integration in the Ambxst AI Sidebar.
- Automatic Wayland window and open-folder context via `axctl` (Hyprland/Niri/Mango) and `/proc`.
- Real-time streaming command cards, step progress bar, collapsible outputs, and Stop control.
- Native Settings -> Mods configuration panel.
