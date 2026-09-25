#!/bin/bash
# Read a Guix dry run (`guix ... -n`) on stdin and fail if it would build
# anything besides Roguix's own packages and derivations Guix marks as local
# builds (preferLocalBuild: configuration files, profile hooks, grafts,
# GRUB's image). Anything else is a package bordeaux has no substitute for.
# Run in the builder VM, where the listed .drv files exist, with GUIX set to
# the same Guix as the dry run:
#   export GUIX="guix time-machine --commit=C --"
#   $GUIX system build -n --no-grafts -L guest/guix/modules \
#     guest/guix/system.scm 2>&1 | guest/guix/check-builds.sh
set -euo pipefail
modules=$(cd "$(dirname "$0")/modules/roguix" && pwd)

# NAME-VERSION of each package Roguix's modules define, unexported ones too.
names=$(mktemp)
trap 'rm -f "$names"' EXIT
${GUIX:-guix} repl -L "$modules/.." -- /dev/stdin > "$names" <<'SCHEME'
(use-modules (guix packages))
(for-each
 (lambda (name)
   (module-for-each
    (lambda (symbol variable)
      (when (and (variable-bound? variable)
                 (package? (variable-ref variable)))
        (let ((package (variable-ref variable)))
          (format #t "~a-~a~%" (package-name package)
                  (package-version package)))))
    (resolve-module name)))
 '((roguix packages) (roguix apps) (roguix omarchy) (roguix integrations)
   (roguix services) (roguix system)))
SCHEME
ours=$(sort -u "$names")
[[ -n $ours ]] || { echo "check-builds: found no Roguix packages" >&2; exit 2; }

# The dry run lists derivations to build between "would be built:" and the
# next heading; each is an indented /gnu/store/...drv path.
drvs=$(awk '/would be built:/ { on = 1; next }
            /would be (downloaded|fetched)|^[^ ]/ { on = 0 }
            on && /\.drv$/ { print $1 }')

unexpected=0
for drv in $drvs; do
  name=$(basename "$drv" .drv | cut -d- -f2-)
  if grep -q '"preferLocalBuild","1"' "$drv"; then
    continue
  fi
  for package in $ours; do
    # PACKAGE-VERSION, or PACKAGE-VERSION-OUTPUT for another output.
    [[ $name == "$package" || $name == "$package"-* ]] && continue 2
  done
  echo "would build: $name"
  unexpected=$((unexpected + 1))
done

count=$(wc -w <<< "$drvs")
if (( unexpected )); then
  echo "check-builds: $unexpected of $count derivations have no substitutes" >&2
  exit 1
fi
echo "check-builds: $count derivations to build, all Roguix's own or local"
