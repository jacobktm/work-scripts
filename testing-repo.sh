#!/usr/bin/env bash

if [ "$#" -ne 3 ]; then
  echo "Usage: $0 <user or org> <repo-name> <pr-num>"
  exit 1
fi

USER_ORG=$1
REPO=$2
PR_NUM=$3
BRANCH_NAME="testing-${REPO}-pr${PR_NUM}"

echo $BRANCH_NAME

if [ ! -d "$HOME/Git" ]; then
  mkdir -p "$HOME/Git"
fi

cd "$HOME/Git"

if [ -e "$REPO" ]; then
  rm -rf "$REPO"
fi

git clone "git@github.com:${USER_ORG}/${REPO}.git"
cd "$REPO"

echo "Fetching PR #${PR_NUM} as branch: ${BRANCH_NAME}..."
if ! git fetch origin pull/"${PR_NUM}"/head:"${BRANCH_NAME}"; then
  echo "Error: Unable to fetch PR #${PR_NUM}. Verify that the PR exists and that this is the correct repo."
  exit 1
fi
echo "Checking out ${BRANCH_NAME}..."
if ! git checkout "${BRANCH_NAME}"; then
  echo "Error: Failed to checkout ${BRANCH_NAME}."
  exit 1
fi
echo "Pushing ${BRANCH_NAME} to origin..."
if ! git push origin "${BRANCH_NAME}"; then
  echo "Error: Failed to push ${BRANCH_NAME} to origin."
  exit 1
fi
echo "Success. CI/CD should start building package for ${BRANCH_NAME}."
