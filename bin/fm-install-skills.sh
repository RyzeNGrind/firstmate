#!/usr/bin/env bash
# Install or verify symlinks for Claude skills from the firstmate repo.
# Reads $FM_ROOT/.agents/skills/ and creates symlinks at ~/.claude/skills/<skill-name>.
# Usage: fm-install-skills.sh
#        Prints one line per action (created/updated/skipped) and exits 0 on success.
#        Does not overwrite real directories or files - only updates or creates symlinks.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
SKILLS_SOURCE="$FM_ROOT/.agents/skills"
SKILLS_TARGET="${HOME}/.claude/skills"

# Create target directory if it doesn't exist
mkdir -p "$SKILLS_TARGET" || exit 1

# Iterate over all skill directories in .agents/skills/
if [ ! -d "$SKILLS_SOURCE" ]; then
  exit 0
fi

for skill_dir in "$SKILLS_SOURCE"/*; do
  [ -d "$skill_dir" ] || [ -L "$skill_dir" ] || continue

  skill_name=$(basename "$skill_dir")
  target_link="$SKILLS_TARGET/$skill_name"

  # Determine the expected target (always the original skill_dir, even if skill_dir is a symlink)
  expected_target="$skill_dir"

  # Check if target link exists
  if [ -L "$target_link" ]; then
    # It's a symlink - check if it points to the right place
    current_target=$(readlink "$target_link")
    if [ "$current_target" = "$expected_target" ]; then
      echo "skipped: $skill_name (already correct)"
    else
      # Update the symlink to point to the correct target
      rm "$target_link"
      ln -s "$expected_target" "$target_link"
      echo "updated: $skill_name"
    fi
  elif [ -e "$target_link" ] || [ -L "$target_link" ]; then
    # Target exists but is not a symlink - don't overwrite it
    echo "skipped: $skill_name (existing file/directory, not overwriting)"
  else
    # Target doesn't exist - create the symlink
    ln -s "$expected_target" "$target_link"
    echo "created: $skill_name"
  fi
done

exit 0
