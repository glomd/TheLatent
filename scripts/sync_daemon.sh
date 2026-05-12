#!/data/data/com.termux/files/usr/bin/bash

REPO="$HOME/thelatent"

cd $REPO

echo "Batch sync daemon started..."

while true; do

  if [[ -n $(git status --porcelain) ]]; then

    echo "Changes detected..."

    git add -A

    git commit -m "batch sync $(date '+%Y-%m-%d %H:%M:%S')"

    git push origin main

    echo "Synced."

  fi

  sleep 30

done
