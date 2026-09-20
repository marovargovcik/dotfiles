export EDITOR=nvim
export VISUAL=nvim
export PATH="$HOME/.local/bin:$PATH"
export PATH="$PATH:$HOME/.local/share/coursier/bin"

command -v mise >/dev/null && eval "$(mise activate bash --shims)"

[ -f $HOME/.config/user-dirs.dirs ] && set -a && . $HOME/.config/user-dirs.dirs && set +a
[ -f $HOME/.bashrc ] && . $HOME/.bashrc

if [ -z "$WAYLAND_DISPLAY" ] && [ "$(tty)" = "/dev/tty1" ]; then
    export XDG_CURRENT_DESKTOP=sway
    export XDG_SESSION_TYPE=wayland
    exec dbus-run-session ssh-agent sway
fi
