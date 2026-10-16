cask "whispr-stream" do
  version "1.0.4"
  sha256 "11c65536459997e8df6d4ea42d259c951a48145f46f2eb0268e8e1e46e9a3bcc"

  url "https://github.com/Leo6Leo/whispr-stream/releases/download/v#{version}/WhisprStream-macos-arm64.zip"
  name "WhisprStream"
  desc "Private, local speech-to-text dictation for Apple silicon Macs"
  homepage "https://leo6leo.github.io/whispr-stream/"

  livecheck do
    url :url
    strategy :github_latest
  end

  auto_updates true
  depends_on arch: :arm64
  depends_on macos: :sonoma

  app "WhisprStream.app"

  postflight_steps do
    run "/usr/bin/xattr", args: ["-rd", "com.apple.quarantine", "{{appdir}}/WhisprStream.app"]
  end

  uninstall quit: "com.leoleo.whisprstream"

  zap trash: [
    "~/Library/Application Support/WhisprStream",
    "~/Library/Logs/WhisprStream.log",
    "~/Library/Preferences/com.leoleo.whisprstream.plist",
  ]

  caveats <<~EOS
    WhisprStream is self-signed and is not notarized by Apple. This Cask removes
    the quarantine attribute only from the installed WhisprStream.app so it can
    launch without the Open Anyway step. It does not disable Gatekeeper.

    On first launch, follow Setup Guide to install the speech engine and model,
    then grant Microphone and Accessibility access.
  EOS
end
