# Homebrew cask TEMPLATE for the MaulTeam Mac app (distribution channel ③).
#
# This file is the source of truth. It is NOT a live cask on its own — the
# __VERSION__ / __SHA256__ placeholders are rendered by macapp/scripts/bump-tap.sh
# on each Release publish and the result is pushed to the tap repo
# (sohei56/homebrew-tap) as Casks/maul-team.rb. End users install with:
#
#   brew tap sohei56/homebrew-tap
#   brew install --cask maul-team
#
cask "maul-team" do
  version "__VERSION__"
  sha256 "__SHA256__"

  url "https://github.com/sohei56/maul-team/releases/download/v#{version}/MaulTeam-#{version}.dmg"
  name "Maul Team for Claude Code"
  desc "Native macOS app that runs a multi-agent Claude Code Scrum team"
  homepage "https://github.com/sohei56/maul-team"

  # Matches LSMinimumSystemVersion (14.0) in make-app.sh's Info.plist.
  depends_on macos: :sonoma

  # The app self-updates via Sparkle (EdDSA-signed appcast). Declaring this
  # stops a plain `brew upgrade` from clobbering a copy Sparkle already moved
  # to a newer version. `brew upgrade --greedy` still reinstalls a
  # same-or-newer cask because bump-tap.sh bumps the tap on every release.
  auto_updates true

  app "MaulTeam.app"

  # The app shells out to these at runtime. Homebrew can't install Claude Code
  # (separate distribution), so surface the prerequisites as caveats rather than
  # failing the install.
  caveats <<~EOS
    MaulTeam.app drives the `claude` CLI inside a terminal pane. You also need:
      • Claude Code  >= 2.1.172   https://claude.com/claude-code
      • Python       >= 3.9       (dashboard — check: python3 --version)
      • tmux and git on your PATH
  EOS

  zap trash: [
    "~/Library/Application Support/MaulTeam",
  ]
end
