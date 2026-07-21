# Guesli Meet Speaker Bridge

Unpacked Chromium extension for local testing.

1. Open `chrome://extensions`.
2. Enable Developer mode.
3. Load unpacked: `browser-extension/muesli-meet-speaker`.
4. Join Google Meet with Guesli running.

After updating the extension files, click **Reload** on `chrome://extensions` and reload the Meet tab so Chromium installs the new manifest and content scripts.

The extension sends only active speaker name samples, visible Meet participant names, and the current Meet URL to `http://127.0.0.1:1477/v1/meet-speaker`.
It enables Meet captions locally once per call and uses only recent caption rows tied to a known participant; it does not scan arbitrary page text for speaker names.
