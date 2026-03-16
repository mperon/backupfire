#!/usr/bin/env bash

usage() {
  echo "Usage: $0 -p <project> -s <server1> [-s <server2> ...]"
  echo "  -p  project path (e.g. org/repo)"
  echo "  -s  server (repeatable)"
  exit 1
}

project="mperon/backupfire"
servers=("gitlab.com" "github.com" "bitbucket.org")

while getopts ":p:s:" opt; do
  case "$opt" in
    p) project="$OPTARG" ;;
    s) servers+=("$OPTARG") ;;
    *) usage ;;
  esac
done

[[ -z "$project" ]] && { echo "Error: -p is required"; usage; }
[[ ${#servers[@]} -eq 0 ]] && { echo "Error: at least one -s is required"; usage; }

git remote remove origin
git remote add origin "git@${servers[0]}:${project}.git"
for url in "${servers[@]}"; do
  git remote set-url --add --push origin "git@${url}:${project}.git"
done
