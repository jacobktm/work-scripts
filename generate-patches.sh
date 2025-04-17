#!/bin/bash

# Usage:
#   ./generate-patches.sh <commits.txt> [output_dir] [--repo /path/to/repo]

COMMITS_FILE=""
OUTPUT_DIR="./patches"
REPO_PATH="."

# --- Parse arguments ---
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --repo)
            REPO_PATH="$2"
            shift 2
            ;;
        -*)
            echo "Unknown option: $1"
            exit 1
            ;;
        *)
            if [[ -z "$COMMITS_FILE" ]]; then
                COMMITS_FILE="$1"
            elif [[ "$OUTPUT_DIR" == "./patches" ]]; then
                OUTPUT_DIR="$1"
            else
                echo "Too many positional arguments."
                exit 1
            fi
            shift
            ;;
    esac
done

# --- Validate arguments ---
if [[ -z "$COMMITS_FILE" || ! -f "$COMMITS_FILE" ]]; then
    echo "❌ Error: Please provide a valid commits file."
    echo "Usage: $0 <commits.txt> [output_dir] [--repo /path/to/repo]"
    exit 1
fi

if [[ ! -d "$REPO_PATH/.git" ]]; then
    echo "❌ Error: '$REPO_PATH' is not a valid git repository."
    exit 1
fi

mkdir -p "$OUTPUT_DIR"

# --- Change to repo path ---
pushd "$REPO_PATH" > /dev/null || exit 1

# --- Generate patches ---
while IFS= read -r commit; do
    if [[ -z "$commit" ]]; then continue; fi
    subject=$(git show -s --format='%s' "$commit" | tr -cd '[:alnum:]._-' | cut -c1-50)
    filename="${commit:0:12}-${subject}.patch"
    echo "Generating patch for $commit -> $filename"
    git show "$commit" > "$OUTPUT_DIR/$filename"
done < "$COMMITS_FILE"

popd > /dev/null
echo "✅ All patches written to: $OUTPUT_DIR"

