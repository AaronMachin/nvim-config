# Terminal tabs in a float, the tab bar and its key hints.
Output docs/gifs/tabs.gif
Set Shell zsh
Set FontFamily "UbuntuMono Nerd Font Mono"
Set FontSize 17
Set Width 1280
Set Height 760
Set Padding 16
Set TypingSpeed 70ms
Set Theme "OneDark"

Hide
Type "docs/demo/run-nvim.sh seed-tabs.lua server.js" Enter
Sleep 5s
Show

Sleep 1.5s
Ctrl+G
Sleep 1.5s
Type "npm start" Enter
Sleep 1.5s
Ctrl+T
Sleep 1.2s
Type "git --no-pager log --oneline" Enter
Sleep 1.5s
Ctrl+B
Sleep 2s
Type "k"
Sleep 2s
Type "r"
Sleep 0.8s
Ctrl+U
Type "server" Enter
Sleep 2s
Type "j"
Sleep 2s
Escape
Sleep 1.5s
Ctrl+G
Sleep 2s
