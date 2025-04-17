#!/bin/bash

# --- Usage help ---
print_usage() {
    echo "Usage: $0 --commit <commit_hash_or_prefix> [--strategy <ours|theirs>] [--repo <path_to_git_repo>]"
    exit 1
}

# --- Parse arguments ---
COMMIT_PARTIAL=""
RESOLVE_STRATEGY=""
REPO_PATH="."

while [[ "$#" -gt 0 ]]; do
    case $1 in
        --commit)
            COMMIT_PARTIAL="$2"
            shift 2
            ;;
        --strategy)
            RESOLVE_STRATEGY="$2"
            shift 2
            ;;
        --repo)
            REPO_PATH="$2"
            shift 2
            ;;
        -h|--help)
            print_usage
            ;;
        *)
            echo "Unknown parameter passed: $1"
            print_usage
            ;;
    esac
done

if [ -z "$COMMIT_PARTIAL" ]; then
    echo "❌ Error: --commit <commit_hash_or_prefix> is required."
    print_usage
fi

if [[ "$RESOLVE_STRATEGY" != "" && "$RESOLVE_STRATEGY" != "ours" && "$RESOLVE_STRATEGY" != "theirs" ]]; then
    echo "❌ Error: --strategy must be 'ours', 'theirs', or omitted."
    exit 1
fi

# --- Change to the specified git repo ---
cd "$REPO_PATH" || { echo "❌ Error: Unable to access directory '$REPO_PATH'"; exit 1; }

# --- Verify it is a Git repo ---
if ! git rev-parse --is-inside-work-tree > /dev/null 2>&1; then
    echo "❌ Error: '$REPO_PATH' is not a Git repository."
    exit 1
fi

# --- Set git editor to vim ---
export GIT_EDITOR=vim

# --- Find the full commit hash ---
FULL_HASH=$(git rev-parse "$COMMIT_PARTIAL" 2>/dev/null)
if [ -z "$FULL_HASH" ]; then
    echo "❌ Error: No matching commit found for '$COMMIT_PARTIAL'"
    exit 1
fi

# --- Shorten the hash if it's a full one ---
SHORT_HASH=$(git log --pretty=format:"%h %H" | awk -v full="$FULL_HASH" '$2 == full { print $1; exit }')
echo "✅ Full commit hash: $FULL_HASH"
echo "🔹 Shortened commit hash: $SHORT_HASH"

# --- Find how many commits back the commit is ---
DISTANCE=$(git rev-list --count $FULL_HASH..HEAD)
REBASE_RANGE=$((DISTANCE + 1))
echo "ℹ️  Commit is $DISTANCE commits behind HEAD. Rebase range: HEAD~$REBASE_RANGE"

# --- Launch rebase ---
git rebase -i HEAD~$REBASE_RANGE

if [ "$RESOLVE_STRATEGY" != "" ]; then
    echo "⚙️  Conflict resolution strategy set to '$RESOLVE_STRATEGY'"
else
    echo "📝 You will be prompted to manually resolve conflicts during rebase."
fi

# --- Conflict resolution function ---
resolve_conflicts_in_file() {
    local file=$1

    if awk '/<<<<<<< HEAD/ {{ in++; }} /=======/ {{ mid++; }} />>>>>>>/ {{ out++; }} END {{ if (in > out) exit 99; }}' "$file"; then
        awk -v STRATEGY="$RESOLVE_STRATEGY" -v file="$file" '
            BEGIN {
                in_conflict = 0;
                conflict_block = "";
            }
            /<<<<<<< HEAD/ {
                if (in_conflict) {
                    print "❗ Nested or malformed conflict detected. Launching manual edit." > "/dev/stderr";
                    system("vim " file " < /dev/tty > /dev/tty 2>&1");
                    exit;
                }
                in_conflict = 1;
                conflict_block = $0 "\n";
                next;
            }
            /=======/ && in_conflict {
                ours = conflict_block;
                gsub(/^<<<<<<< HEAD\n/, "", ours);
                gsub(/\n=======\n.*/, "", ours);
                conflict_block = conflict_block "\n" $0 "\n";
                next;
            }
            />>>>>>>/ && in_conflict {
                theirs = conflict_block;
                gsub(/^.*\n=======\n/, "", theirs);
                gsub(/\n>>>>>>>.*/, "", theirs);
                conflict_block = conflict_block "\n" $0;

                if (STRATEGY == "ours") {
                    resolved_block = ours;
                } else if (STRATEGY == "theirs") {
                    resolved_block = theirs;
                } else {
                    print "Manual edit required in " file > "/dev/stderr";
                    system("vim " file " < /dev/tty > /dev/tty 2>&1");
                    exit;
                }

                print resolved_block;
                in_conflict = 0;
                conflict_block = "";
                next;
            }
            in_conflict {
                conflict_block = conflict_block "\n" $0;
                next;
            }
            {
                print $0;
            }
        ' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
    else
        echo "❗ Detected nested or unmatched conflict markers in $file. Launching vim for manual resolution..."
        vim "$file"
    fi
}

# --- Main conflict resolution loop ---
while true; do
    conflict_files=$(git diff --name-only --diff-filter=U)
    if [ -z "$conflict_files" ]; then
        break
    fi
    for file in $conflict_files; do
        echo "🧩 Resolving: $file"
        resolve_conflicts_in_file "$file"
        git add "$file"
    done
    git rebase --continue || break
done

echo "✅ Rebase process complete."
