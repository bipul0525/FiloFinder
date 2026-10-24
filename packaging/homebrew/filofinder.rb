# Homebrew cask. Lives in the tap repo github.com/bipul0525/homebrew-tap as Casks/filofinder.rb.
# On each release, update `version` and `sha256` (the DMG line in SHA256SUMS).
cask "filofinder" do
  version "0.1.1"
  sha256 "ee56b89fc3db792f0b531e7787b476e0bf2c5ccdfb6646a0e9b672081e478e9f"

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
