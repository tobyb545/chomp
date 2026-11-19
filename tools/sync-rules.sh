#!/bin/sh
# Copies the game rules into the Edge Functions bundle (functions can't import
# files outside supabase/functions). backend/tests checks the copies match.
set -e
cd "$(dirname "$0")/.."
cp shared/rules.json backend/supabase/functions/_shared/chomp/rules.json
echo "rules.json synced"
