# Provider shutdown script (optional - delete this file if you don't need one).
#
# Runs once when the provider tears down, after every resource operation and
# after the practitioner's shutdown_script. Disconnect/clean up here, e.g.:
#
#   Disconnect-ExchangeOnline -Confirm:$false
#
# Like startup.ps1, this runs flat at the runspace scope: do NOT declare a
# param block (the engine prepends its own), and read $global:ProviderData or
# your own globals instead.

$global:YourProviderState = $null
