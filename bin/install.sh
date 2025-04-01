#!/bin/zsh

myName="displays-cli"

## region ############################################## Destination

# Allow setting of destination via prefix, verify that it's writable
destDir="/usr/local/sbin"
[ -n "$1" ] && destDir="$1"
[ ! -w "$destDir" ] && echo "Destination directory '$destDir' is not writable by this user." && exit 1

## endregion ########################################### End Destination

## region ############################################## Main Code

installed=""
if [ -f "$destDir/${myName}" ]; then
  installed="$("$destDir/$myName" --version | /usr/bin/awk '{ print $2 }')"
fi

repoUrl="https://github.com/jonesiscoding/displays-cli/releases/latest"
effectiveUrl=$(curl -Ls -o /dev/null -I -w '%{url_effective}' "$repoUrl")
tag=$(echo "$effectiveUrl" | /usr/bin/rev | /usr/bin/cut -d'/' -f1 | /usr/bin/rev)
[[ "$tag" == "releases" ]] && tag="v1.0"
if [ -n "$tag" ]; then
  # Exit successfully if same version
  [[ "$tag" == "$installed" ]] && exit 0
  dlUrl="https://github.com/jonesiscoding/displays-cli/archive/refs/tags/${tag}.zip"
  repoFile=$(/usr/bin/basename "$dlUrl")
  tmpDir="/private/tmp/displays-cli/${tag}"
  [ -d "$tmpDir" ] && /bin/rm -R "$tmpDir"
  if /bin/mkdir -p "$tmpDir"; then
    if /usr/bin/curl -Ls -o "$tmpDir/$repoFile" "$dlUrl"; then
      cd "$tmpDir" || exit 1
      if /usr/bin/unzip -qq "$tmpDir/$repoFile"; then
        /bin/rm "$tmpDir/$repoFile"
        if /bin/cp "$tmpDir/${myName}-${tag//v/}/src/${myName}" "$destDir/"; then
          /bin/chmod 755 "$destDir/$myName"
          /bin/rm -R "$tmpDir"
          # Success - Exit Gracefully
          exit 0
        fi
      fi
    fi
  fi
fi

# All Paths that lead here indicate we couldn't install
exit 1

## endregion ########################################### End Main Code