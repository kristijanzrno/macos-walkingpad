class Walkingpad < Formula
  desc "Control a KingSmith WalkingPad treadmill from the macOS menu bar"
  homepage "https://github.com/kristijanzrno/macos-walkingpad"
  # SSH, so the tap and the source both work while the repository is private.
  url "git@github.com:kristijanzrno/macos-walkingpad.git", using: :git, tag: "v1.0.1"
  version "1.0.1"
  license "MIT"
  head "git@github.com:kristijanzrno/macos-walkingpad.git", using: :git, branch: "main"

  depends_on xcode: ["16.0", :build]
  depends_on macos: :sonoma

  def install
    system "scripts/build-app.sh"
    prefix.install "build/WalkingPad.app"
    bin.install_symlink prefix/"WalkingPad.app/Contents/MacOS/WalkingPad" => "walkingpad"
  end

  def caveats
    <<~EOS
      Put WalkingPad in your Applications folder (once; upgrades keep the link working):
        ln -sfn #{opt_prefix}/WalkingPad.app /Applications/WalkingPad.app

      Then start it:
        open -a WalkingPad

      The `walkingpad` command controls the running app, e.g. `walkingpad toggle`.
    EOS
  end

  test do
    assert_match "Usage: walkingpad", shell_output("#{bin}/walkingpad help")
  end
end
