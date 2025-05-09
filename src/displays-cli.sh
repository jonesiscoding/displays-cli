#!/bin/zsh

# @file displays-cli
# @description Shows and logs current displays on macOS systems.
# @option --json Output JSON.
# @option --ea Output Jamf Extension Attribute result.
# @option --ca | --attr Output Attribute result, appropriate for some other MDM solutions.
# @option --wake If display is sleeping, wake before polling, re-sleep afterward.
# @option --location <location> Filter log results by the given location.
# @option --schema Display a JSON Schema for the Applications & Custom Settings payload.
# @option --model <model> Filter log results by the given model.
# @option --serial <serial> Filter log results by the given serial number.
# @option --head <number> Show only <number> results from the head of the log, after filtering. Overrides --tail.
# @option --tail <number> Show only <number> results from the tail of the log, after filtering. (Default: 100)
# @option --first Show only the first appearance of the given criteria.  Overrides --last, --head, --tail.
# @option --last Show only the last appearance of the given criteria.  Overrides --head, --tail.
# @option -h | --help Show command help, then exit
# @option --version Display version, then exit
#
# @author AMJones <am@jonesiscoding.com>
# @copyright Copyright (c) 2025 AMJones
# @license MIT License (https://github.com/jonesiscoding/displays-cli/blob/main/LICENSE)
#

# Log Variables
logDate=$(/bin/date +"%Y-%m-%d %H:%M:%S")
logFileRoot="/var/log"

# Output Variables
_out_blue=""
_out_end=""
if [ -n "$TERM" ] && [ "$TERM" != "dumb" ]; then
  _out_blue=$(/usr/bin/tput setaf 4)    #"\033[1;36m"
  _out_end=$(/usr/bin/tput sgr0)   #"\033[0m"
fi

# Verify Root
if [ "${EUID:-$(id -u)}" -ne 0 ] && [[ "$*" != *"--help"* ]] && [[ "$*" != *"--version"* ]] && [[ "$*" != *"--schema"* ]]; then
  [[ "$*" == *"--ea"* ]] && echo "<result>ERROR</result>" && exit 1
  echo "ERROR: This must be run with root or with sudo!" && exit 1
fi

# Other Variables
spDisplaysDataType=$(system_profiler SPDisplaysDataType -json)
ioRegDisplayAttributes=$(/usr/sbin/ioreg -lw0 | /usr/bin/grep -i "DisplayAttributes")
parentCommand="$(ps -o comm= $PPID)"
myArch=$(/usr/bin/arch)
cacheDays=7
myVersion="###version###"

## region ###################################### JSON Functions

# @description Evaluates if the given string resembles a JSON object string
# @exitcode 0 Yes
# @exitcode 1 No
function json-is-object() {
  [[ "${1:0:1}" == "{" ]] && return 0
  return 1
}

# @description Evaluates if the given string resembles a JSON array string
# @exitcode 0 Yes
# @exitcode 1 No
function json-is-array() {
  [[ "${1:0:1}" == "[" ]] && return 0
  return 1
}

# @description Adds the given arguments to the given JSON object string. Multiple key/value pairs can be given.
# @arg $1 string JSON Object String
# @arg $2 string Key
# @arg $3 string Value
function json-obj-add() {
  local obj

  obj="$1"
  shift
  while [[ "$1" != "" ]]; do
    if json-is-object "$2" || json-is-array "$2"; then
      obj=$($eJQ ". += {\"$1\": $2 }" <<< "$obj")
    else
      obj=$($eJQ ". += {\"$1\": \"$2\" }" <<< "$obj")
    fi
    shift
    [ -n "$1" ] && shift
  done

  echo "$obj"
}

# @description Adds the given value to the given JSON array string
# @arg $1 string JSON array String
# @arg $2 string Value
function json-arr-add() {
  if json-is-object "$2" || json-is-array "$2"; then
    $eJQ ". += [ $2 ]" <<< "$1"
  else
    $eJQ ". += [ \"$2\" ]" <<< "$1"
  fi
}

## endregion ################################### JSON Functions

## region ###################################### Preference Functions

# @description Turns host.domain.com into com.domain.host
# @noargs
# @stdout The reversed domain
function prefs-reverse-domain() {
  echo "$1" | /usr/bin/sed 's/https:\/\///' | /usr/bin/sed 's/\/$//' | /usr/bin/awk -F. '{s="";for (i=NF;i>1;i--) s=s sprintf("%s.",$i);$0=s $1}1'
}

# @description Gets the bundle prefix to use for retrieval of organization managed preferences, first by utilizing the
# MDM_BUNDLE_PREFIX environment variable, then the domain portion of the host name, then the jss_url (if available),
# and defaulting to org.yourname if no other options can be resolved.
# @noargs
# @stdout string The bundle prefix
function prefs-bundle-prefix() {
  local hostname len prefix

  prefix="$MDM_BUNDLE_PREFIX"

  if [ -z "$prefix" ]; then
    hostname=$(/bin/hostname -f)
    len="${hostname//[^\.]}"
    len=${#len}
    if [ "${len}" -ge "3" ]; then
      prefix=$(prefs-reverse-domain "$hostname" | /usr/bin/cut -d'.' -f-$((len-1)) )
    fi
  fi

  if [ -z "$prefix" ]; then
    jamfHost=$(defaults-read "/Library/Preferences/com.jamfsoftware.jamf.plist" jss_url)
    [ -n "$jamfHost" ] && prefix=$(prefs-reverse-domain "$jamfHost")
  fi

  echo "${prefix:-org.yourname}"
}

function prefs-set-jq-path() {
  eJQ=$(which jq)
  [ ! -x "$eJQ" ] && eJQ=$(defaults read "$plistManaged" jq_path 2>/dev/null)
  [ ! -x "$eJQ" ] && eJQ=$(defaults read "$plistSystem" jq_path 2>/dev/null)
  [ ! -x "$eJQ" ] && eJQ="/usr/local/bin/jq"
  [ ! -x "$eJQ" ] && eJQ="/opt/homebrew/bin/jq"
  [ ! -x "$eJQ" ] && eJQ="/opt/local/bin/jq"
  [ ! -x "$eJQ" ] && return 1

  return 0
}

# @description Sets the $logStaticLocation variable if found in the managed, user, or system preferences.
# @noargs
function prefs-set-static-location() {
  local plists plist

  plists=("$plistManaged" "$plistUser" "$plistSystem")

  for plist in $plists; do
    val=$(defaults read "$plist" static_location 2>/dev/null)
    if [ -n "$val" ]; then
      logStaticLocation="$val"

      return 0
    fi
  done
}

# @description Sets the $logPrivacy variable if found in the managed, user, or system preferences.
# @noargs
function prefs-set-log-privacy() {
  local plists plist

  plists=("$plistManaged" "$plistUser" "$plistSystem")

  for plist in $plists; do
    val=$(defaults read "$plist" privacy_level 2>/dev/null)
    if [ -n "$val" ]; then
      logPrivacy="$val" && return 0
    fi
  done
}

# @description Sets the $plistUser variable, if a user is logged in.
# @noargs
function prefs-set-user-plist() {
  local consoleUser

  consoleUser=$(echo "show State:/Users/ConsoleUser" | /usr/sbin/scutil | /usr/bin/awk '/Name :/ && ! /loginwindow/ { print $3 }')
  [ -n "$consoleUser" ] && plistUser="/Users/$consoleUser/Library/Preferences/$plistName"
}

# Preference Variables
logPrivacy=0
logStaticLocation=""
prefsBundlePrefix=$(prefs-bundle-prefix)
prefsBundleSuffix="displays-cli"
plistName="${prefsBundlePrefix}.${prefsBundleSuffix}.plist"
plistManaged="/Library/Managed Preferences/${plistName}"
plistSystem="/Library/Preferences/${plistName}"
logFile="${logFileRoot}/${prefsBundlePrefix}.${prefsBundleSuffix}.log"
[ ! -f "$logFile" ] && touch "$logFile"
prefs-set-user-plist
prefs-set-static-location
prefs-set-log-privacy

## endregion ################################### Preference Functions

## region ###################################### Output Functions

# @description Print Key in Blue & Value in standard text color, separated by ...
# @args $1 string Key
# @args $2 string Value
# @stdout string The key and value displayed in an easy-to-read fashion
function output() {
  local padding="............................................................................"
  printf "${_out_blue}%s${_out_end}%s %s\n" "$1" "${padding:${#1}}" "$2"
}

# @description Print output in blue
# @arg $1 string Text to Print
function output-blue() {
  echo "${_out_blue}${1}${_out_end}"
}

function output-bundle() {
  echo "$prefsBundlePrefix.$prefsBundleSuffix"
}

# @description Prints the script name and version
# @noargs
# @stdout string Script name & version
function output-version() {
  echo "displays-cli v${myVersion}"
}

# @description JSON Schema for the Applications & Custom Settings payload
# @noargs
# @stdout string JSON Schema
function output-schema() {
  cat <<HEREDOC
{
  "title": "Mac Displays ($prefsBundlePrefix.$prefsBundleSuffix)",
  "description": "Settings for the Displays Script",
  "links": [
    {
      "rel": "Source",
      "href": "https://github.com/jonesiscoding/mac-displays"
    },
  ],
  "properties": {
    "privacy_level": {
      "title": "Privacy Level",
      "description": "Controls how non-matching locations are logged, allowing for user privacy for displays at unmanaged locations.",
      "type": "integer",
      "default": 0,
      "enum": [
          0,
          1,
          2
      ],
      "options": {
          "enum_titles": [
              "Use IP for Non-Matching Locations",
              "Use NA for Non-Matching Locations",
              "Do Not Log at Non-Matching Locations"
          ]
      }
    },
    "static_location": {
      "type": "string",
      "title": "Static Location Name",
      "description": "Only used if you are setting up location-specific Configuration Profiles instead of IP matching."
    },
    "jq_path": {
      "type": "string",
      "title": "Path to 'jq' Executable",
      "description": "If 'jq' is not in path, and this is not set, the following are tried: /usr/bin/jq, /usr/local/bin/jq, /opt/homebrew/bin/jq, /opt/local/bin/jq"
    },
    "locations": {
      "type": "array",
      "items": {
        "type": "object",
        "properties": {
          "pattern": {
            "type": "string",
            "title": "Grep Extended Regex Pattern",
            "description": "The pattern to match an external IPv4 address to."
          },
          "name": {
            "type": "string",
            "title": "Name"
          }
        }
      }
    }
  }
}
HEREDOC
}

# @description Outputs help text
# @noargs
# @stdout string Help Text
function output-usage() {
  echo ""
  output-blue "$(output-version)"
  echo "  Output & log information about the displays attached to a macOS system, or search previous entries."
  echo "  This utility must be run as root (or via sudo) due to macOS restrictions."
  echo ""
  output-blue "Syntax:"
  echo ""
  echo "  displays --json"
  echo "  displays --ea"
  echo "  displays --first --location Building_1"
  echo ""
  output-blue "Output Flags"
  echo ""
  echo "  --json            Show output As JSON String"
  echo "  --ea              Show output as Jamf Extension Attribute result."
  echo "  --attr            Show output as an 'attribute' suitable for some other MDM solutions."
  echo "  --wake            If display is sleeping, wake before polling, then re-sleep display after polling."
  echo "  --schema          Display a JSON Schema for the Applications & Custom Settings payload."
  echo "  --version         Shows version & quits."
  echo "  --help            Shows this help text & quits."
  echo ""
  output-blue "Search Flags"
  echo ""
  echo "  --location <name>  Search for log entries for the given location. Any pattern that works with grep works."
  echo "  --model <name>     Search for log entries for the given model name. Any pattern that works with grep works."
  echo "  --serial <name>    Search for log entries for the given serial number. Any pattern that works with grep works."
  echo "  --head <number>    Limit entries to the given number from the head of the log. "
  echo "  --tail <number>    Limit entries to the given number from the tail of the log. "
  echo "  --first            Only show the first entry for the given criteria."
  echo "  --last             Only show the last entry for the given criteria."
  echo "  --version          Shows version & quits."
  echo "  --bundleid         Shows bundle ID & quits."
  echo "  --help             Shows this help text & quits."
  echo ""
}

## endregion ################################### Output Functions

## region ###################################### Location Functions

# @description Gets the external IP address of the device
# @noargs
# @stdout string IPv4 Address
function location-ip() {
  /usr/bin/dig +short myip.opendns.com @resolver1.opendns.com
}

# @description Evaluates if the given IP matches one of the locations in the given JSON.
# @arg $1 string JSON string containing an array of { pattern: <pattern>, name: <name> } objects
# @arg $2 string IPv4 to Match
# @stdout string Name of Matching Location
# @exitcode 0 Found
# @exitcode 1 Not Found
function location-match() {
  local locations lc li pattern ip

  locations="$1"
  ip="$2"

  lc=$($eJQ '.locations | length' <<< "$locations")
  for ((li=0; li <= (lc-1); li++)); do
    pattern=$($eJQ -r ".locations[$li].pattern" <<< "$locations" | sed 's/\\\\/\\/g')
    if echo "$ip" | /usr/bin/grep -E -q "$pattern"; then
      $eJQ -r ".locations[$li].name" <<< "$locations" && return 0
    fi
  done

  return 1
}

# @description Prints a location name if the given IP matches one of the patterns in the given plist.
# @arg $1 string IPv4
# @arg $2 string Path to Plist
# @stdout string Location Name (Default: NA)
function location-from-ip-plist() {
  local locations match plist ip

  ip="$1"
  plist="$2"
  if [ -f "$plist" ]; then
    locations=$(plutil -convert json -o - "$plist")
    match=$(location-match "$locations" "$ip")
    if [ -n "$match" ]; then
      echo "$match" && return 0
    fi
  fi

  return 1
}

# @description Prints location matching the current external IP to configured patterns in managed/system/user prefs.
# @noargs
# @stdout string Location Name (Default: NA)
function location-from-ip() {
  local ip match

  match=""
  if [ -z "$logStaticLocation" ]; then
    ip=$(location-ip)
    match=$(location-from-ip-plist "$ip" "$plistManaged" || location-from-ip-plist "$ip" "$plistUser" || location-from-ip-plist "$ip" "$plistSystem")

    if [ -z "$match" ]; then
      if [ "$logPrivacy" -eq "0" ]; then
        match="$ip"
      elif [ "$logPrivacy" -eq "1" ]; then
        match="NA"
      fi
    fi
  else
    match="$logStaticLocation"
  fi

  echo "$match"
}

## endregion ################################### End Location Functions

## region ###################################### Log Functions

# @description Adds the given data to the log
# @arg $1 string Model
# @arg $2 string Serial Number
function log-entry() {
  local location

  location=$(location-from-ip)
  if [ -n "$location" ]; then
    if [ -n "$2" ]; then
      echo "[$logDate] [$location] Model: $1; SN: $2" >> "$logFile"
    else
      echo "[$logDate] [$location] Model: $1;" >> "$logFile"
    fi
  fi
}

# @description Returns the log entries for the given location name
# @arg $1 string Location Name
# @stdout string Log lines for given location name
function log-for-location() {
  /usr/bin/grep "\[$1\]" "$logFile"
}

# @description Parses the given log line and prints the date
# @arg $1 string Log Line
# @stdout string Date in the format: YYYY-MM-DD HH:MM:SS
function log-line-date() {
  echo "$1" | /usr/bin/awk -F'] ' '{ print $1 }' | /usr/bin/awk -F'[' '{ print $2 }'
}

# @description Parses the given log line and prints the model
# @arg $1 string Log Line
# @stdout string Date in the format: YYYY-MM-DD HH:MM:SS
function log-line-model() {
  echo "$1" | /usr/bin/awk -F'] ' '{ print $3 }' | /usr/bin/awk -F'; ' '{ print $1 }' | /usr/bin/sed 's/Model: //'
}

# @description Determines the difference between the date in the given log line and now.
# @arg $1 string Log Line
# @stdout int    Number of Days
function log-diff() {
  local thenD nowS thenS diffS diffD line

  line="$1"
  thenD=$(log-line-date "$line")
  if [ -n "$thenD" ]; then
    nowS=$(/bin/date +"%s")
    thenS=$(/bin/date -f "%Y-%m-%d %H:%M:%S" "$thenD" +"%s")
    diffS=$((nowS - thenS))
    diffD=$((diffS / (60 * 60 * 24)))
  fi

  echo ${diffD:-0}
}

## endregion ################################### End Log Functions

## region ###################################### Power Functions

# @description Evaluates if the display is sleeping
# @noargs
# @exitcode 0 Yes
# @exitcode 1 No
is-display-sleep() {
  isWrangle=true
  [[ "$myArch" == "amd64" ]] && isWrangle=false
  [[ "$(get-adapter-count)" -gt "1" ]] && isWrangle=false
  if $isWrangle; then
    /usr/bin/pmset -g powerstate IODisplayWrangler | /usr/bin/tail -1 | /usr/bin/grep -v "failure" | /usr/bin/cut -c29 | /usr/bin/grep -qE '^[0-3]$'
  else
    /usr/bin/pmset -g log | /usr/bin/grep -e " Sleep  " -e " Wake  " | /usr/bin/tail -n1 | /usr/bin/awk '{ print $4 }' | /usr/bin/grep -q "Sleep"
  fi
}

## region ###################################### Power Functions

## region ###################################### SPDisplaysDataType Functions

# @description Gets the adapter count from SPDisplaysDataType
# @noargs
# @stdout int Count
function get-adapter-count() {
  $eJQ -r '.SPDisplaysDataType | length' <<< "$spDisplaysDataType"
}

# @description Gets the monitor count from SPDisplaysDataType for the given adapter
# @arg $1 int Adapter Index
# @stdout int Count
function get-monitor-count() {
  $eJQ -r ".SPDisplaysDataType[$1].spdisplays_ndrvs | length" <<< "$spDisplaysDataType"
}

# @description Gets the total monitor count from SPDisplaysDataType for all adapters
# @noargs
# @stdout int Count
function get-total-monitor-count() {
  local adpC monC totC amI

  totC=0
  adpC=$(get-adapter-count)
  for ((amI=0; amI <= (adpC-1); amI++)); do
    monC=$(get-monitor-count "$amI")
    totC=$((totC+monC))
  done

  echo "$totC" && return 0
}

# @description Gets the adapter model from the sppci_model key of SPDisplaysDataType for the given adapter
# @arg $1 int Adapter Index
# @stdout string Model
function adapter-model() {
  $eJQ -r ".SPDisplaysDataType[$1].sppci_model//empty" <<< "$spDisplaysDataType"
}

# @description Gets the value for the given key for the given adapter & monitor index
# @arg $1 int Adapter Index
# @arg $2 int Monitor Index
# @stdout string Value
function monitor_value() {
  $eJQ -r ".SPDisplaysDataType[$1].spdisplays_ndrvs[$2].\"${3}\"//empty" <<< "$spDisplaysDataType" | /usr/bin/grep -v -E '^$'
}

# @description Gets the _name value from SPDisplaysDataType ->spdisplays_ndrvs for the given adapter & monitor index
# @arg $1 int Adapter Index
# @arg $2 int Monitor Index
# @stdout string Monitor Model Name
function monitor-name() {
  monitor_value "$1" "$2" "_name"
}

# @description Gets the _spdisplays_display-serial-number value from SPDisplaysDataType -> spdisplays_ndrvs.
# @arg $1 int Adapter Index
# @arg $2 int Monitor Index
# @stdout string Serial Number
function monitor-serial() {
   monitor_value "$1" "$2" "spdisplays_display-serial-number" || monitor_value "$1" "$2" "_spdisplays_display-serial-number"
}

# @description Gets the resolution part of the _spdisplays_resolution value from SPDisplaysDataType -> spdisplays_ndrvs.
# @arg $1 int Adapter Index
# @arg $2 int Monitor Index
# @stdout string Resolution
function monitor-resolution() {
  echo "$(monitor_value "$1" "$2" "spdisplays_resolution" || monitor_value "$1" "$2" "_spdisplays_resolution")" | /usr/bin/awk -F' @ ' '{ print $1 }'
}

# @description Gets the refresh part of the _spdisplays_resolution value from SPDisplaysDataType -> spdisplays_ndrvs.
# @arg $1 int Adapter Index
# @arg $2 int Monitor Index
# @stdout string Refresh Rate
function monitor-refresh() {
  echo "$(monitor_value "$1" "$2" "spdisplays_resolution" || monitor_value "$1" "$2" "_spdisplays_resolution")" | /usr/bin/awk -F' @ ' '{ print $2 }'
}

# @description Gets the _spdisplays_pixels value from SPDisplaysDataType -> spdisplays_ndrvs.
# @arg $1 int Adapter Index
# @arg $2 int Monitor Index
# @stdout string Pixels
function monitor-pixels() {
  monitor_value "$1" "$2" "_spdisplays_pixels"
}

# @description Gets the _spdisplays_display-year value from SPDisplaysDataType -> spdisplays_ndrvs.
# @arg $1 int Adapter Index
# @arg $2 int Monitor Index
# @stdout int Year
function monitor-year() {
  monitor_value "$1" "$2" "_spdisplays_display-year"
}

# @description Evaluates the _spdisplays_ambient-brightness value from SPDisplaysDataType -> spdisplays_ndrvs.
# @arg $1 int Adapter Index
# @arg $2 int Monitor Index
# @exitcode 0 On
# @exitcode 1 Off
function monitor-is-ambient-brightness() {
  monitor_value "$1" "$2" "_spdisplays_ambient-brightness" | /usr/bin/grep -q "yes"
}

# @description Evaluates the spdisplays_main value from SPDisplaysDataType -> spdisplays_ndrvs.
# @arg $1 int Adapter Index
# @arg $2 int Monitor Index
# @exitcode 0 Yes - Is Main
# @exitcode 1 No
function monitor-is-main() {
  monitor_value "$1" "$2" "spdisplays_main" 2>/dev/null | /usr/bin/grep -q "yes"
}

# @description Evaluates the spdisplays_mirror value from SPDisplaysDataType -> spdisplays_ndrvs.
# @arg $1 int Adapter Index
# @arg $2 int Monitor Index
# @exitcode 0 Yes - Is Mirror
# @exitcode 1 No
function monitor-is-mirror() {
  monitor_value "$1" "$2" "spdisplays_mirror" 2>/dev/null | /usr/bin/grep -q -v "off"
}

## endregion ################################### SPDisplayDataType Functions

## region ###################################### IOReg Functions

# @description Gets the value for the given key from ioreg -lw0 | grep "DisplayAttributes"
# @arg $1 string Key
# @stdout string Value
function display_attribute() {
  local key value filter index

  key="$1"
  index="${2:-0}"
  filter="${3}"
  value="$ioRegDisplayAttributes"
  [ -n "$filter" ] && value=$(echo "$value" | /usr/bin/grep "$filter" )
  [ -n "$index" ] && value=$(echo "$value" | /usr/bin/sed -n "$((index+1))p" )

  echo "$value" | /usr/bin/grep -oE "\"${key}\"=\"[^\"]+\"" | /usr/bin/cut -d"=" -f2 | /usr/bin/tr -d '"'
}

# @description Gets the count of lines from ioreg -lw0 | grep "DisplayAttributes"
# @arg $1 string Key
# @stdout string Value
function display-attribute-count() {
  echo "$ioRegDisplayAttributes" | /usr/bin/wc -l | /usr/bin/xargs
}

# @description Gets the ProductName value from ioreg -lw0 | grep "DisplayAttributes"
# @arg $1 string Key
# @stdout string Value
function display-attribute-model() {
  display_attribute "ProductName" "$@"
}

# @description Gets the AlphanumericSerialNumber value from ioreg -lw0 | grep "DisplayAttributes"
# @arg $1 string Key
# @stdout string Value
function display-attribute-serial() {
  display_attribute "AlphanumericSerialNumber" "$@"
}

# @description Gets the AlphanumericSerialNumber value from ioreg -lw0 | grep "DisplayAttributes"
# @arg $1 string Key
# @stdout string Value
function display-attribute-year() {
  display_attribute "YearOfManufacture" "$@"
}

# @description Gets the NativeFormatHorizontalPixels x NativeFormatVerticalPixels values from ioreg -lw0 | grep "DisplayAttributes"
# @arg $1 string Key
# @stdout string Value
function display-attribute-resolution() {
  printf "%s x %s" "$(display_attribute NativeFormatHorizontalPixels "$@")" "$(display_attribute NativeFormatVerticalPixels "$@")"
}

## endregion ################################### IOReg Functions

## region ###################################### Main Function

# @description Compiles JSON string containing an array of display objects
# @noargs
# @stdout JSON string
function get-json-data() {
  local json ac ai mAdapter amc ami tmc cmc
  local mModel mSerial mYear mPixels mResolution mRefresh mJson
  json="[]"
  tmc=$(get-total-monitor-count)
  cmc=0
  ac=$(get-adapter-count)
  if [ "$ac" -gt "0" ]; then
    for ((ai=0; ai <= (ac-1); ai++)); do
      mAdapter=$(adapter-model "$ai" || echo "$ai")
      amc=$(get-monitor-count "$ai")
      if [ "$amc" -gt "0" ]; then
        cmc=$((cmc+amc))
        for ((ami=0; ami <= (amc-1); ami++)); do
          mModel=$(monitor-name "$ai" "$ami" || echo "")
          mSerial=$(display-attribute-serial "$ami" "$mModel" )
          [ -z "$mSerial" ] && mSerial=$(monitor-serial "$ai" "$ami" || echo "")
          mYear=$(monitor-year "$ai" "$ami" || echo "")
          mPixels=$(monitor-pixels "$ai" "$ami" || echo "")
          mResolution=$(monitor-resolution "$ai" "$ami" || echo "")
          mRefresh=$(monitor-refresh "$ai" "$ami" || echo "")
          log-entry "$mModel" "$mSerial"
          mJson=$(json-obj-add "{}" adapter "$mAdapter" model "$mModel" serial "$mSerial" pixels "$mPixels" refresh "$mRefresh")
          mJson=$(json-obj-add "$mJson" resolution "$mResolution" year "$mYear")
          if monitor-is-ambient-brightness "$ai" "$ami"; then
            mJson=$(json-obj-add "$mJson" "is_ambient_brightness" "true")
          else
            mJson=$(json-obj-add "$mJson" "is_ambient_brightness" "false")
          fi
          if monitor-is-main "$ai" "$ami"; then
            mJson=$(json-obj-add "$mJson" "is_main" "true")
          else
            mJson=$(json-obj-add "$mJson" "is_main" "false")
          fi
          if monitor-is-mirror "$ai" "$ami"; then
            mJson=$(json-obj-add "$mJson" "is_mirror" "true")
          else
            mJson=$(json-obj-add "$mJson" "is_mirror" "false")
          fi
          mJson=$(json-obj-add "$mJson" "is_sleep" "false")
          json=$(json-arr-add "$json" "$mJson")
        done
      elif is-display-sleep; then
        mJson=$(json-obj-add "{}" is_sleep "true")
        json=$(json-arr-add "$json" "$mJson")
      fi
    done
  fi

  if [ "$tmc" -lt "1" ]; then
    amc=$(display-attribute-count)
    if [ "$amc" -gt "0" ]; then
      for ((ami=0; ami <= (amc-1); ami++)); do
        mModel=$(display-attribute-model "$ami")
        mSerial=$(display-attribute-serial "$ami" "$mModel")
        mYear=$(display-attribute-year "$ami" "$mModel")
        mResolution=$(display-attribute-resolution "$ami" "$mModel")
        if [ -n "$mModel" ] || [ -n "$mSerial" ]; then
          log-entry "$mModel" "$mSerial"
          mJson=$(json-obj-add "{}" model "$mModel" serial "$mSerial" year "$mYear" resolution "$mResolution")
          json=$(json-arr-add "$json" "$mJson")
        fi
      done
    fi
  fi

  echo "$json"
}

## endregion ################################### Main Function

## region ###################################### Input Handling

isJson=false
isJamfEa=false
isAttr=false
isFirst=false
isLast=false
isSearch=false
isWake=false
model=""
serial=""
location=""
tail=100

if echo "$parentCommand" | /usr/bin/grep "jamf" && [ "$#" -eq 0 ]; then
  isJamfEa=true
else
  while [ "$1" != "" ]; do
    # Check for our added flags
    case "$1" in
        --first )                   isSearch=true; isFirst=true;              ;;
        --last )                    isSearch=true; isLast=true;               ;;
        --head )                    isSearch=true; head="$2";                 shift ;;
        --tail )                    isSearch=true; tail="$2";                 shift ;;
        --location )                isSearch=true; location="$2";             shift ;;
        --model )                   isSearch=true; model="$2";                shift ;;
        --serial )                  serial="$2";                              shift ;;
        --wake )                    isWake=true;                              ;;
        --json)                     isJson=true                               ;;
        --ea )                      isJamfEa=true                             ;;
        --attr | --ca )             isAttr=true                               ;;
        --bundleid )                output-bundleid;                          exit; ;; # show bundle ID and quit
        --schema )                  output-schema;                            exit; ;; # show schema and quit
        --help )                    output-usage;                             exit; ;; # show help and quit
        --version )                 output-version;                           exit; ;; # show version and quit
    esac
    shift # move to next kv pair
  done
fi

if ! prefs-set-jq-path; then
  $isJamfEa && echo "<result>Error</result>" && exit 0
  $isAttr && echo "ERROR" && exit 0
  ! $isSearch && echo "ERROR: JQ does not seem to be installed." && exit 1
fi

if $isWake && is-display-sleep; then
  # Stay Awake for TTY
  ttyskeepawake=$(/usr/bin/pmset -g | /usr/bin/grep ttyskeepawake | /usr/bin/awk '{ print $2 }')
  [ -z "$ttyskeepawake" ] && /usr/bin/pmset -a ttyskeepawake 1
  # Stay Awake for 150 seconds
  /usr/bin/caffeinate -d -u -t 150 &
  caffePid=$!
  # Use a Wake Event
  curS=$(/bin/date -j "+%s")
  wakS=$((curS+30))
  wakD=$(/bin/date -j -f "%s" "$wakS" "+%m/%d/%g %H:%M:%S")
  /usr/bin/pmset schedule wake "$wakD"
  # Wait for the Wake Event
  /bin/sleep 45
  # Regather Info
  spDisplaysDataType=$(/usr/sbin/system_profiler SPDisplaysDataType -json)
else
  isWake=false
fi

## endregion ################################### Input Handling

## region ###################################### Log Search Controller

if $isSearch; then
  result=$(/bin/cat "$logFile")
  if [ -n "$model" ]; then
    result=$(echo "$result" | /usr/bin/grep "$model")
  fi

  if [ -n "$serial" ]; then
    result=$(echo "$result" | /usr/bin/grep "; $serial")
  fi

  if [ -n "$location" ]; then
    result=$(echo "$result" | /usr/bin/grep "[$location]")
  fi

  if $isLast; then
    echo "$result" | /usr/bin/tail -1
  elif $isFirst; then
    echo "$result" | /usr/bin/head -1
  elif [ -n "$head" ]; then
    echo "$result" | /usr/bin/head -"$head"
  elif [ -n "$tail" ]; then
    echo "$result" | /usr/bin/tail -"$tail"
  else
    echo "$result"
  fi
  exit 0
fi

## endregion ################################### Log Search Controller

## region ###################################### Output Controller

json=$(get-json-data)
if $isJson; then
  $eJQ <<< "$json"
elif $isJamfEa || $isAttr; then
  count=$($eJQ -r '. | length' <<< "$json")
  if [ "$count" -gt "0" ]; then
    ea=()
    for ((i=0; i <= (count-1); i++)); do
      isSleep=$($eJQ -r ".[$i].is_sleep" <<< "$json")
      if [[ "$isSleep" == "true" ]]; then
        ea+=("Sleeping")
        location=$(location-from-ip)
        if [ -n "$location" ]; then
          last=$(/usr/bin/grep "\[$location\]" "$logFile" | /usr/bin/tail -1)
          lastDiff=$(log-diff "$last")
          if [ "$lastDiff" -lt "$cacheDays" ]; then
            lastDate=$(log-line-date "$last")
            last=$(/usr/bin/grep "\[$location\]" "$logFile" | /usr/bin/grep "\[$lastDate\]")
            for line in ${(f)last}; do
              ea+=("$(log-line-model "$line")")
            done
          fi
        fi
      else
        ea+=("$($eJQ -r ".[$i].model" <<< "$json")")
      fi
    done
  else
    ea=("None")
  fi

  result="${(j[|])ea}"
  $isJamfEa && echo "<result>$result</result>" && exit 0
  echo "$result"
else
  count=$($eJQ '. | length' <<< "$json")
  if [ "$count" -eq "0" ]; then
    echo "No Displays Detected"
  else
    for ((i=0; i <= (count-1); i++)); do
      if [[ "$($eJQ -r ".[$i].is_sleep" <<< "$json")" == "true" ]]; then
        echo "Display ${i} is Sleeping; Details Unavailable"
      else
        output "Adapter" "$($eJQ -r ".[$i].adapter" <<< "$json")"
        output "Model" "$($eJQ -r ".[$i].model" <<< "$json")"
        output "Serial Number" "$($eJQ -r ".[$i].serial" <<< "$json")"
        output "Year" "$($eJQ -r ".[$i].year" <<< "$json")"
        output "Max Resolution" "$($eJQ -r ".[$i].pixels" <<< "$json")"
        output "Resolution" "$($eJQ -r ".[$i].resolution" <<< "$json")"
        output "Refresh" "$($eJQ -r ".[$i].refresh" <<< "$json")"
        output "Is Main?" "$($eJQ -r ".[$i].is_main" <<< "$json")"
        output "Is Mirror?" "$($eJQ -r ".[$i].is_mirror" <<< "$json")"
        output "Is Ambient Brightness?" "$($eJQ -r ".[$i].is_ambient_brightness" <<< "$json")"
      fi
      [ "$count" -gt "1" ] && echo "---------------------------------------------------"
    done
  fi
  if $isWake; then
    # shellcheck disable=SC2086
    [ -n "$caffePid" ] && kill $caffePid
    [ -z "$ttyskeepawake" ] && /usr/bin/pmset -a ttyskeepawake 0
    /usr/bin/pmset displaysleepnow
  fi
fi
exit 0

## endregion ################################### Output Controller
