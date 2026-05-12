#!/data/data/com.termux/files/usr/bin/bash

while inotifywait -r -e modify,create,delete 00_Contracts; do
    git add .
    git commit -m "auto sync $(date)"
    git push
done

