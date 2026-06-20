# Homebrew cask for AI Markdown Viewer.
#
# This is the source of truth. To publish, copy it into your tap repo
# (github.com/Chrismacolor/homebrew-tap) under Casks/, updating `version` and
# `sha256` to match the released DMG (release.sh prints the sha256). Users then:
#
#   brew tap Chrismacolor/tap
#   brew install --cask ai-markdown-viewer
#
# Updates flow through `brew upgrade` — no in-app updater (keeps the app
# zero-dependency).

cask "ai-markdown-viewer" do
  version "1.0.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/Chrismacolor/ai-markdown-viewer/releases/download/v#{version}/AIMarkdownViewer-#{version}.dmg"
  name "AI Markdown Viewer"
  desc "Lightweight, native macOS Markdown viewer"
  homepage "https://github.com/Chrismacolor/ai-markdown-viewer"

  depends_on macos: ">= :ventura"

  app "AIMarkdownViewer.app"

  zap trash: [
    "~/Library/Preferences/com.disanto.aimarkdownviewer.plist",
  ]
end
