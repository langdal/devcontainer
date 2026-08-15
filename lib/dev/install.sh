# shellcheck shell=bash
# lib/dev/install.sh — `dev install`: symlink this script onto PATH and offer
# the zsh completion line. Sourced by dev; not executed directly.

# cmd_install <dev-script-path>: the `dev install` verb. The script's own path
# is passed in by the router because ${BASH_SOURCE[0]} inside this module would
# resolve to the module file instead of the dev script the symlink must target.
cmd_install() {
  install_self "$1"
  exit 0
}

# install_self <dev-script-path>: create the PATH symlink (refusing to clobber
# anything that is not already our own link) and, interactively, offer to add
# the compdef line to ~/.zshrc.
install_self() {
  local script_path
  script_path="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"

  local target_dir=""
  local candidates=("$HOME/.local/bin" "$HOME/bin" "/usr/local/bin")
  for dir in "${candidates[@]}"; do
    case ":$PATH:" in
      *":$dir:"*)
        if [[ -d "$dir" && -w "$dir" ]]; then
          target_dir="$dir"
          break
        fi
        ;;
    esac
  done

  if [[ -z "$target_dir" ]]; then
    echo "Error: No writable bin directory found on PATH." >&2
    echo "Expected one of: ${candidates[*]}" >&2
    echo "Create one and add it to PATH, then retry." >&2
    exit 1
  fi

  local link="$target_dir/dev"
  if [[ -L "$link" ]]; then
    local current
    current="$(readlink "$link")"
    if [[ "$current" == "$script_path" ]]; then
      echo "Already installed: $link -> $script_path"
    else
      echo "Error: $link already exists and points to $current" >&2
      echo "Remove it first: rm $link" >&2
      exit 1
    fi
  elif [[ -e "$link" ]]; then
    echo "Error: $link exists and is not a symlink. Refusing to overwrite." >&2
    exit 1
  else
    ln -s "$script_path" "$link"
    echo "Installed: $link -> $script_path"
  fi

  local zshrc="$HOME/.zshrc"
  local compdef_line='compdef _gnu_generic dev'
  if [[ -f "$zshrc" ]] && grep -qxF -- "$compdef_line" "$zshrc"; then
    echo "zsh completion already configured in ~/.zshrc"
    return
  fi

  if [[ ! -t 0 ]]; then
    echo "To enable tab-completion, add this line to ~/.zshrc:  $compdef_line"
    return
  fi

  local reply
  read -r -p "Add '$compdef_line' to ~/.zshrc to enable tab-completion? [y/N] " reply
  case "$reply" in
    y|Y|yes|YES)
      {
        echo ""
        echo "# Added by 'dev install': enable tab-completion for the dev script"
        echo "$compdef_line"
      } >> "$zshrc"
      echo "Added compdef line to ~/.zshrc. Run 'exec zsh' to activate."
      ;;
    *)
      echo "Skipped. You can add it later with: echo '$compdef_line' >> ~/.zshrc"
      ;;
  esac
}
