# Homebrew cask for Margins — a native macOS Markdown reader.
# https://github.com/Chrismacolor/margins
#
# Maintained in the app repo (homebrew/margins.rb) and mirrored verbatim to the
# tap (Chrismacolor/homebrew-tap, under Casks/). On each release, bump `version`
# + `sha256` to the new DMG (release.sh prints the sha256), then copy this file
# into the tap. Install:
#
#   brew install --cask Chrismacolor/tap/margins
#
# Updates flow through `brew upgrade` — no in-app updater (keeps the app
# zero-dependency).

cask "margins" do
  version "1.0.1"
  sha256 "e853b671aa05156541a4e35751982e4e7ff8b92a5e967f811ca21f0c0fe8b0b5"

  url "https://github.com/Chrismacolor/margins/releases/download/v#{version}/Margins-#{version}.dmg"
  name "Margins"
  desc "Native Markdown reader for macOS"
  homepage "https://github.com/Chrismacolor/margins"

  depends_on macos: :ventura

  app "Margins.app"

  zap trash: [
    "~/Library/Preferences/com.disanto.margins.plist",
  ]
end
