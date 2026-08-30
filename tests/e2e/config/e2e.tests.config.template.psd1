# Blueprint for the gitignored live-system E2E config. Copy it to
# e2e.tests.config.psd1 (same directory) and fill in real values; suites load
# it via Get-E2ETestConfig and skip cleanly when the file is absent, so CI
# stays green on machines without access to the target system.
#
# Shape it however your provider needs; a common layout:
@{
    # Enabled  = $true
    # Endpoint = 'https://example.invalid'
    # Username = 'svc-terraform'
    # Password = 'TBD'   # 'TBD' should be treated as "not configured" by your suites
}
