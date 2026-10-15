# Homebrew cask. Lives in the tap repo github.com/bipul0525/homebrew-tap as Casks/filofinder.rb.
# On each release, update `version` and `sha256` (the DMG line in SHA256SUMS).
cask "filofinder" do
  version "0.1.0"
  sha256 "dafa2392aff628689e3a91163ed118f3734e669e9679de7c004b16414a684aee"

  url "https://github.com/bipul0525/FiloFinder/releases/download/v#{version}/Filofinder-#{version}.dmg"
  name "FiloFinder"
  desc "Fast, free, open-source Finder alternative with cut & paste and split view"
  homepage "https://github.com/bipul0525/FiloFinder"

  auto_updates true
  depends_on macos: ">= :ventura"

  app "Filofinder.app"

  # Not notarised (no paid Apple account): remove the download quarantine.
  postflight do
    system_command "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "#{appdir}/Filofinder.app"]
  end

  zap trash: [
    "~/Library/Preferences/app.filofinder.plist",
    "~/Library/Caches/app.filofinder",
    "~/Library/Application Support/Filofinder",
  ]
end
