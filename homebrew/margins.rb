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
  version "1.0.3"
  sha256 "37d4a521edcb74b097e593b91a2166056779d84f4f77c3754fb9d9c91773faa6"

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
