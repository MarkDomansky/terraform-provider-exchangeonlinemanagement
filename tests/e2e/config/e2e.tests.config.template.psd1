# Blueprint for the gitignored live-tenant E2E config. Copy it to
# e2e.tests.config.psd1 (same directory) and fill in real values. The suites
# load it via Get-E2ETestConfig and skip cleanly when the file is absent or
# when Enabled is $false, so CI stays green without a tenant.
#
# Prerequisites (see docs/guides/):
#   - ExchangeOnlineManagement 3.0.0+ installed on this machine
#   - an Entra app registration with a certificate, the Exchange.ManageAsApp
#     application permission (admin-consented), and an Exchange role assignment
#
# These tests CREATE AND DELETE REAL MAILBOXES in the tenant you point them at.
# Use a test tenant. Every object they create is named with the MailboxPrefix
# below plus a GUID, and is removed in the suite's cleanup.
@{
    # Set to $true once the values below are real.
    Enabled = $false

    # Tenant primary domain, e.g. contoso.onmicrosoft.com.
    Organization = 'TBD'

    # Entra application (client) ID.
    AppId = 'TBD'

    # Authentication: set EITHER CertificateThumbprint (Windows only) OR
    # CertificatePath (+ CertificatePassword, all platforms). Setting both is
    # rejected by the provider.
    CertificateThumbprint = ''
    CertificatePath       = ''
    CertificatePassword   = ''

    # Prefix for every mailbox the suite creates, so leftovers from a crashed
    # run are identifiable and easy to clean up by hand.
    MailboxPrefix = 'tf-e2e'

    # Optional: an existing mailbox to exercise the data source against without
    # creating one. Leave empty to use the mailbox the suite creates.
    ExistingMailbox = ''
}
