# Displays CLI
Shell script for identifying and logging displays attached to macOS systems, designed to be used in a business 
environment. The utility must be run by an MDM or by a macOS administrator using sudo, typically over SSH.

Allows filtering of logs by model, serial, and location, as well as configuration via MDM or system plist.

## Purpose

To allow for easy recording which systems have which kind of display, and to make end-user support easier.

Also may be handy in environments where users may feel the need to make unauthorized display swaps with another
workstation, allowing admins to configure their MDM for notification of changes, and to research the history of changes.

## Installation

Installation is manual at this time; view the raw content of `displays-cli` and place it in your chosen location in the
path of system.  The recommended path is `/usr/local/sbin/displays`.

## Dependencies

* The `jq` executable.  This is native on macOS Sequoia or higher, or must be installed via other methods.
* __One__ of the following:
    * A hostname that is a Fully Qualified Domain Name
    * A Jamf Pro instance
    * Setting a `MDM_BUNDLE_PREFIX` environment variable (`org.yourname`)

## Standard Usage

Output can be shown as standard text or by using the `--json` flag, a JSON array.  Included in the output are the model,
serial number, max resolution, current resolution, current refresh rate, year of manufacture, and boolean indicators of
whether the display is main, mirrored, and using ambient brightness.

### Sleeping Displays

The display information is unavailable from the OS if the display is sleeping. If you want to wake the display before
polling, the `--wake` flag may be used.  This may not work in all environments.

## Logging & Searching

When the utility is run, each attached display is logged with a date, location, model, and serial number.  Location
matches are determined via the preferences, as configured by MDM or system/user plist.

Using the `--model`, `--serial`, and `--location` flags, the log may be filtered and displayed.  The `--last`, `--first`,
`--head` and `--tail` flags may be used to limit the results. By default, only the last 100 entries are shown.

### MDM Attribute

Using the `--ea` or `--attr` flags (or run as a Jamf Pro Extension Attribute script) the output is the model of each
display shown as a pipe separated string.

To ensure accurate data, if a display is sleeping, the result is based on logged values.  Only a value logged
within the last 7 days with the same location is used.  The result will also add "Sleeping|" prior to the model(s).

When running as a Jamf Pro Extension Attribute script or using the `--ea` flag, output is enclosed in
`<result></result>` as required.

## Configuration

Configuration can be done by setting values in an MDM installed configuration profile, system preferences, or user
preferences using your preferred tool.

### Configuration Profile Keys

| Key             | Description                                                                                                                                                   |
|-----------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------|
| privacy_level   | 0 - Use IP for Non-Matching Locations<br/>1 - Use NA for Non-Matching Locations<br/>3 - Do Not Log at Non-Matching Locations                                  |
| jq_path         | Path to JQ if not in the path, and not in a standard location.                                                                                                |
| locations       | Array of dictionary objects with 'pattern' and 'name' keys.<br/>Pattern to match the external IP address(es) of your location(s).<br/>Name is used in the log |
| static_location | The location name to use.  Overrides configured location patterns.<br/>Only recommended for single location businesses with desktop systems.                  |

### Jamf Configuration

If using Jamf, configuration is easy. Install displays-cli on your local Jamf system, and run `displays --schema` to
output a JSON schema compatible with the Jamf Pro Configuration Profile -> Application & Custom Settings payload.

Verify that the schema shows a proper reverse domain at the top.  This is based on one of the following settings, in
order of precedence:

* The MDM_BUNDLE_PREFIX environment variable
* The hostname of the machine, if using a FQDN
* The hostname of your Jamf instance

### Other MDM Configuration

This utility should work with any MDM that allows for configuration profiles. To see the application domain to use for
your configuration profile, look at the output of `displays --schema`.

Contributions of knowledge or code are welcome to allow this tool to be used easily on other MDM solutions.  The tool
should work in any situation where it can be configured via MDM

### Manual Configuration

Using a tools such as PlistBuddy, you should be able to add the appropriate keys and values to a plist file.  To see the 
expected name for your plist look at the output of `displays --bundleid`.  For system-wide settings, the plist file should
be:

    /Library/Preferences/<org.yourname>.displays-cli.plist

Automatic configuration may be added in a later version. 