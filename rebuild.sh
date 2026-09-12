#!/bin/bash
set -e
rm -f scrollsense.db scrollsense.db-wal scrollsense.db-shm
sqlite3 scrollsense.db < schema.sql
python3 generate_data.py
sqlite3 scrollsense.db < views.sql
echo "rebuilt"
