# Provider startup script (optional - delete this file if you don't need one).
#
# Runs once per terraform run, after the engine is configured (and after any
# remote session is opened), BEFORE the practitioner's startup_script.
# This is the place to authenticate and load modules, e.g.:
#
#   Import-Module ExchangeOnlineManagement
#   Connect-ExchangeOnline -CertificateThumbprint $global:ProviderData.cert_thumbprint ...
#
# Available context:
#   $global:ProviderData          - built-in provider args (server, username, ...)
#   $global:ProviderData.Config   - YOUR custom attributes from provider/provider.tfps.json
#
# Contract: do NOT declare a param block here. Unlike a CRUD script, a
# lifecycle script runs flat at the runspace scope (that is what lets it create
# globals that outlive the call), and the engine prepends its own param block -
# a second one would be a parse error. Take your inputs from
# $global:ProviderData instead.
#
# Also: do not write to the error stream (that fails provider startup) and pipe
# any unwanted cmdlet output to Out-Null. Globals you create here persist for
# every resource script because the PowerShell process is persistent.

$global:YourProviderState = @{
    default_directory = $global:ProviderData.Config.default_directory
}
