#!/bin/bash
# Prints a terminal prefix so callers can run: $(bash ./terminal.sh …) bash -lc 'cmd'
# gnome-terminal / cosmic-term use:  term --flags -- bash -lc 'cmd'
# xterm uses:                        xterm -name … -T … -e bash -lc 'cmd'

ARGS=""
if [ $# -gt 0 ]; then
  ARGS="$* "
fi

os_name=$(awk -F= '/^ID=/{gsub(/"/,"",$2); print $2}' /etc/os-release)
session="${XDG_SESSION_DESKTOP:-}"
case ":${XDG_CURRENT_DESKTOP:-}:" in *:COSMIC:*) session=COSMIC ;; esac

choose_terminal_by_session() {
  case "${session}" in
    COSMIC)
      terminal="cosmic-term"
      ;;
    gnome|Ubuntu|ubuntu|ubunt|pop|POP|Pop)
      terminal="gnome-terminal"
      ;;
    kde|plasma)
      terminal="konsole"
      ;;
    xfce)
      terminal="xfce4-terminal"
      ;;
    mate)
      terminal="mate-terminal"
      ;;
    *)
      if [ "${XDG_SESSION_TYPE:-}" = wayland ] && command -v cosmic-term >/dev/null 2>&1; then
        terminal="cosmic-term"
      elif command -v gnome-terminal >/dev/null 2>&1; then
        terminal="gnome-terminal"
      else
        terminal="xterm"
      fi
      ;;
  esac
}

emit_invocation() {
  if [ "$terminal" = "xterm" ]; then
    local _n="xterm" _t="xterm" _a
    for _a in "$@"; do
      case "$_a" in
        --name=*) _n="${_a#--name=}" ;;
        --title=*) _t="${_a#--title=}" ;;
      esac
    done
    printf '%s\n' "xterm -name ${_n} -T ${_t} -e"
  else
    printf '%s\n' "$terminal ${ARGS}--"
  fi
}

case "$os_name" in
  debian|ubuntu|pop|fedora|arch)
    choose_terminal_by_session
    ./install.sh "$terminal"
    emit_invocation "$@"
    ;;
  *)
    echo "Unsupported OS" >&2
    exit 1
    ;;
esac
