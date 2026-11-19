# The Homebrew cask for Agneta, kept here and copied into olofd/homebrew-tap by .github/workflows/homebrew.yml
# when a release is published, with the version and each architecture's DMG checksum filled in (docs/RELEASING.md).
cask "agneta" do
  arch arm: "arm64", intel: "x86_64"

  version "@VERSION@"
  sha256 arm:   "@SHA256_ARM64@",
         intel: "@SHA256_X86_64@"

  url "https://github.com/olofd/agneta/releases/download/v#{version}/Agneta-#{version}-#{arch}.dmg"
  name "Agneta"
  desc "The AI you already pay for, in the Mac apps you choose"
  homepage "https://agneta.dahlbom.io"

  livecheck do
    url :url
    strategy :github_latest
  end

  # Agneta updates itself (Sparkle); brew leaves that to it.
  auto_updates true
  depends_on macos: ">= :sonoma"

  app "Agneta.app"

  # What Reset Agneta removes, less its Keychain items, which only the app can find.
  zap trash: [
    "~/Library/Application Support/com.objectivecoder.agneta",
    "~/Library/Application Support/com.objectivecoder.agneta Workspaces",
    "~/Library/Caches/com.objectivecoder.agneta",
    "~/Library/HTTPStorages/com.objectivecoder.agneta",
    "~/Library/Logs/Agneta",
    "~/Library/Preferences/com.objectivecoder.agneta.plist",
  ]

  caveats <<~EOS
    Open Agneta from Applications. It lives in the menu bar (the linked rings beside the clock), not in the Dock.
  EOS
end
