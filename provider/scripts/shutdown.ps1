# Provider shutdown script. Runs once on teardown, AFTER the practitioner's
# shutdown_script - the mirror of startup.ps1's ordering.
#
# CONTRACT: no param block (see startup.ps1).
#
# Teardown is best-effort. Anything on the error stream fails the operation, so
# a failed disconnect must not be allowed to fail an otherwise successful
# terraform run - hence the deliberately empty catch.

try {
    if (Get-Command -Name 'Disconnect-ExchangeOnline' -ErrorAction Ignore) {
        # -Confirm:$false is mandatory. Disconnect-ExchangeOnline has a high
        # ConfirmImpact, and a confirmation prompt in the sidecar's
        # non-interactive host blocks until the operation times out.
        Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
    }
}
catch {
    # Intentionally swallowed: see above.
}

$global:EXOProviderState = $null
