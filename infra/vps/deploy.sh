#!/usr/bin/env bash
# Installed as /opt/avancekids/deploy.sh and used as the SSH key's forced command.
# GitHub sends: ssh root@VPS 'app|site COMMIT_SHA' < release.tar.gz
set -euo pipefail
umask 077

read -r kind revision extra <<< "${SSH_ORIGINAL_COMMAND:-${1:-}}"
[[ "$kind" = app || "$kind" = site ]] || { echo 'Invalid application'; exit 2; }
[[ "$revision" =~ ^[0-9a-f]{40}$ && -z "$extra" ]] || { echo 'Invalid revision'; exit 2; }
root=/opt/avancekids
exec 9>"$root/deploy.lock"
flock -w 900 9

if [[ "$kind" = app ]]; then
  base="$root/apps"
  [[ -f "$root/RESTORE_VERIFIED" ]] || { echo 'Initial database restore has not been verified'; exit 1; }
else
  base="$root/site"
fi

stage=$(mktemp -d "$base/releases/.incoming.XXXXXX")
trap '[[ -z "${stage:-}" ]] || rm -rf -- "$stage"' EXIT
# Python's data filter rejects traversal, absolute paths and escaping symlinks.
python3 -c 'import sys,tarfile; tarfile.open(fileobj=sys.stdin.buffer,mode="r|gz").extractall(sys.argv[1],filter="data")' "$stage"

compose=(docker compose --project-directory "$root/supabase" --env-file "$root/supabase/.env"
  -f "$root/supabase/docker-compose.yml" -f "$root/infra/compose.yml")

if [[ "$kind" = app ]]; then
  test -s "$stage/apps/mobile/dist/index.html"
  test -s "$stage/apps/backoffice/dist/index.html"
  test -d "$stage/supabase/migrations"
  test -d "$stage/supabase/functions"
  backup="$root/backups/pre-deploy-$(date -u +%Y%m%dT%H%M%SZ)-$revision.dump"
  "${compose[@]}" exec -T db pg_dump -U supabase_admin -d postgres -Fc > "$backup"
  test -s "$backup"
  "${compose[@]}" exec -T db pg_restore --list < "$backup" > /dev/null
  database_url=$(python3 -c 'from pathlib import Path; from urllib.parse import quote; d=dict(l.split("=",1) for l in Path("/opt/avancekids/supabase/.env").read_text().splitlines() if l and not l.startswith("#") and "=" in l); print("postgresql://postgres:"+quote(d["POSTGRES_PASSWORD"],safe="")+"@127.0.0.1:15432/postgres?sslmode=disable")')
  # db push preserves migration history and stops on a failed migration.
  "$root/bin/supabase" db push --workdir "$stage" --db-url "$database_url" --yes
  mkdir -p "$stage/supabase/functions/main"
  cp "$root/supabase-upstream/docker/volumes/functions/main/index.ts" "$stage/supabase/functions/main/index.ts"
else
  test -s "$stage/.output/server/index.mjs"
fi

# Each retry gets its own directory; running containers keep the previous release.
release="$revision-$(date -u +%Y%m%dT%H%M%S)-$$"
chmod -R a+rX "$stage"
mv "$stage" "$base/releases/$release"
stage=''
previous=$(readlink "$base/current" || true)
ln -s "releases/$release" "$base/.next-$$"
mv -Tf "$base/.next-$$" "$base/current"

if [[ "$kind" = app ]]; then services=(functions web); else services=(site); fi
if ! "${compose[@]}" up -d --no-deps --force-recreate --wait --wait-timeout 180 "${services[@]}"; then
  if [[ -n "$previous" ]]; then
    ln -s "$previous" "$base/.rollback-$$"
    mv -Tf "$base/.rollback-$$" "$base/current"
    "${compose[@]}" up -d --no-deps --force-recreate --wait "${services[@]}"
  fi
  echo 'Deploy failed; previous application restored. Database migrations were not reversed.'
  exit 1
fi
printf '%s %s\n' "$kind" "$revision" >> "$root/deployments.log"
echo "Deployed $kind $revision"
