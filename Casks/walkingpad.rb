cask "walkingpad" do
  version "1.1.0"
  sha256 "ef7a2805a8a7cf9776a6a6f7e265ffce8befe7241819af4b2dc6c2643e298c16"

  url "https://github.com/kristijanzrno/macos-walkingpad/releases/download/v#{version}/WalkingPad-#{version}.zip"
  name "WalkingPad"
  desc "Control a KingSmith WalkingPad treadmill from the menu bar"
  homepage "https://github.com/kristijanzrno/macos-walkingpad"

  depends_on macos: ">= :sonoma"

  app "WalkingPad.app"
  binary "#{appdir}/WalkingPad.app/Contents/MacOS/WalkingPad", target: "walkingpad"

  # The app is ad-hoc signed, not notarized, so Gatekeeper would refuse to
  # open the downloaded copy.
  postflight do
    system_command "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "#{appdir}/WalkingPad.app"]
  end

  uninstall quit: "io.github.kristijanzrno.walkingpad"

  zap trash: [
    "~/Library/Application Support/WalkingPad",
    "~/Library/Preferences/io.github.kristijanzrno.walkingpad.plist",
  ]
end
