# Homebrew cask for Margins.
#
# This is the source of truth. To publish, copy it into your tap repo
# (github.com/Chrismacolor/homebrew-tap) under Casks/, updating `version` and
# `sha256` to match the released DMG (release.sh prints the sha256). Users then:
#
#   brew tap Chrismacolor/tap
#   brew install --cask margins
#
# Updates flow through `brew upgrade` — no in-app updater (keeps the app
# zero-dependency).

cask "margins" do
  version "1.0.0"
  sha256 "30e59763b448ba584d665ec7cb838223f097b549c4c79ff0eea7c7f30ac52d33"

  url "https://github.com/Chrismacolor/margins/releases/download/v#{version}/Margins-#{version}.dmg"
  name "Margins"
  desc "Native Markdown reader for macOS"
  homepage "https://github.com/Chrismacolor/margins"

  depends_on macos: ">= :ventura"

  app "Margins.app"

  zap trash: [
    "~/Library/Preferences/com.disanto.margins.plist",
  ]
end
