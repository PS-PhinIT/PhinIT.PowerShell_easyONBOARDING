<#
.SYNOPSIS
    Stub-Funktionen für externe Cmdlets (ActiveDirectory, Exchange, Microsoft Graph, Entra Connect).

.DESCRIPTION
    Die Stubs werden global definiert und verdecken damit ggf. installierte echte Cmdlets
    (Funktionen haben Vorrang vor Cmdlets). Ein nicht gemockter Aufruf führt zu einer Exception.
    Die Parameterlisten decken alle von easyONBOARDING verwendeten Parameter ab, damit Pester-Mocks
    mit ParameterFilter arbeiten können.

    Die Analyzer-Ausnahmen gelten nur für diese Datei: Die Stubs bilden die Signaturen der echten
    Cmdlets nach (einschließlich -WhatIf/-Confirm und Parameternamen wie ChangePasswordAtLogon),
    verwenden die Parameter aber bewusst nicht.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Signaturen der nachgebildeten Cmdlets.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSShouldProcess', '', Justification = 'Stubs werfen bei jedem nicht gemockten Aufruf.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', '', Justification = 'Nur Schalter wie ChangePasswordAtLogon, keine Kennwörter.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingUsernameAndPasswordParams', '', Justification = 'Signatur von New-ADUser; Kennwort als SecureString.')]
param()

function global:Invoke-EobUnmockedStub {
    param([string]$Name)
    throw "Test-Stub '$Name' wurde aufgerufen, ohne gemockt zu sein. Tests dürfen keine echten Systeme ansprechen."
}

# ---------------------------------------------------------------- ActiveDirectory
function global:Get-ADDomain {
    [CmdletBinding()]
    param([object]$Identity, [string]$Server, [pscredential]$Credential)
    Invoke-EobUnmockedStub -Name 'Get-ADDomain'
}
function global:Get-ADDomainController {
    [CmdletBinding()]
    param([object]$Identity, [switch]$Discover, [switch]$Writable, [string]$DomainName, [string]$Server, [object]$Service, [string]$Filter)
    Invoke-EobUnmockedStub -Name 'Get-ADDomainController'
}
function global:Get-ADForest {
    [CmdletBinding()]
    param([object]$Identity, [string]$Server)
    Invoke-EobUnmockedStub -Name 'Get-ADForest'
}
function global:Get-ADRootDSE {
    [CmdletBinding()]
    param([string]$Server, [string[]]$Properties)
    Invoke-EobUnmockedStub -Name 'Get-ADRootDSE'
}
function global:Get-ADUser {
    [CmdletBinding()]
    param([object]$Identity, [string]$Filter, [string]$LDAPFilter, [string[]]$Properties, [string]$Server,
        [string]$SearchBase, [object]$SearchScope, [object]$ResultSetSize, [pscredential]$Credential)
    Invoke-EobUnmockedStub -Name 'Get-ADUser'
}
function global:New-ADUser {
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$Name, [string]$SamAccountName, [string]$UserPrincipalName, [string]$GivenName, [string]$Surname,
        [string]$DisplayName, [string]$Path, [securestring]$AccountPassword, [object]$Enabled, [object]$ChangePasswordAtLogon,
        [string]$Description, [string]$Title, [string]$Department, [string]$Company, [string]$Office, [string]$OfficePhone,
        [string]$MobilePhone, [string]$EmailAddress, [string]$EmployeeID, [string]$EmployeeNumber, [string]$StreetAddress,
        [string]$City, [string]$PostalCode, [string]$Country, [string]$State, [string]$HomeDirectory, [string]$HomeDrive,
        [string]$ProfilePath, [string]$ScriptPath, [object]$AccountExpirationDate, [object]$Manager, [string]$HomePage,
        [string]$Initials, [hashtable]$OtherAttributes, [object]$PasswordNeverExpires, [object]$SmartcardLogonRequired,
        [string]$Server, [switch]$PassThru)
    Invoke-EobUnmockedStub -Name 'New-ADUser'
}
function global:Set-ADUser {
    [CmdletBinding(SupportsShouldProcess)]
    param([object]$Identity, [hashtable]$Replace, [hashtable]$Add, [hashtable]$Remove, [string[]]$Clear, [string]$Description,
        [object]$Manager, [object]$ChangePasswordAtLogon, [object]$Enabled, [string]$DisplayName, [string]$GivenName,
        [string]$Surname, [string]$Title, [string]$Department, [string]$Company, [string]$Office, [string]$OfficePhone,
        [string]$MobilePhone, [string]$EmailAddress, [string]$HomeDirectory, [string]$HomeDrive, [string]$ProfilePath,
        [string]$Server, [switch]$PassThru)
    Invoke-EobUnmockedStub -Name 'Set-ADUser'
}
function global:Remove-ADUser {
    [CmdletBinding(SupportsShouldProcess)]
    param([object]$Identity, [string]$Server)
    Invoke-EobUnmockedStub -Name 'Remove-ADUser'
}
function global:Remove-ADObject {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param([object]$Identity, [switch]$Recursive, [string]$Server)
    Invoke-EobUnmockedStub -Name 'Remove-ADObject'
}
function global:Get-ADObject {
    [CmdletBinding()]
    param([object]$Identity, [string]$Filter, [string]$LDAPFilter, [string[]]$Properties, [string]$Server,
        [string]$SearchBase, [object]$SearchScope, [object]$ResultSetSize)
    Invoke-EobUnmockedStub -Name 'Get-ADObject'
}
function global:Set-ADObject {
    [CmdletBinding(SupportsShouldProcess)]
    param([object]$Identity, [hashtable]$Replace, [string[]]$Clear, [object]$ProtectedFromAccidentalDeletion, [string]$Server)
    Invoke-EobUnmockedStub -Name 'Set-ADObject'
}
function global:Move-ADObject {
    [CmdletBinding(SupportsShouldProcess)]
    param([object]$Identity, [string]$TargetPath, [string]$Server, [switch]$PassThru)
    Invoke-EobUnmockedStub -Name 'Move-ADObject'
}
function global:Get-ADGroup {
    [CmdletBinding()]
    param([object]$Identity, [string]$Filter, [string]$LDAPFilter, [string[]]$Properties, [string]$Server,
        [string]$SearchBase, [object]$ResultSetSize)
    Invoke-EobUnmockedStub -Name 'Get-ADGroup'
}
function global:Get-ADGroupMember {
    [CmdletBinding()]
    param([object]$Identity, [switch]$Recursive, [string]$Server)
    Invoke-EobUnmockedStub -Name 'Get-ADGroupMember'
}
function global:Add-ADGroupMember {
    [CmdletBinding(SupportsShouldProcess)]
    param([object]$Identity, [object[]]$Members, [string]$Server)
    Invoke-EobUnmockedStub -Name 'Add-ADGroupMember'
}
function global:Remove-ADGroupMember {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param([object]$Identity, [object[]]$Members, [string]$Server)
    Invoke-EobUnmockedStub -Name 'Remove-ADGroupMember'
}
function global:Get-ADPrincipalGroupMembership {
    [CmdletBinding()]
    param([object]$Identity, [string]$Server)
    Invoke-EobUnmockedStub -Name 'Get-ADPrincipalGroupMembership'
}
function global:Get-ADOrganizationalUnit {
    [CmdletBinding()]
    param([object]$Identity, [string]$Filter, [string]$LDAPFilter, [string[]]$Properties, [string]$Server,
        [string]$SearchBase, [object]$SearchScope, [object]$ResultSetSize)
    Invoke-EobUnmockedStub -Name 'Get-ADOrganizationalUnit'
}
function global:Disable-ADAccount {
    [CmdletBinding(SupportsShouldProcess)]
    param([object]$Identity, [string]$Server)
    Invoke-EobUnmockedStub -Name 'Disable-ADAccount'
}
function global:Enable-ADAccount {
    [CmdletBinding(SupportsShouldProcess)]
    param([object]$Identity, [string]$Server)
    Invoke-EobUnmockedStub -Name 'Enable-ADAccount'
}
function global:Set-ADAccountPassword {
    [CmdletBinding(SupportsShouldProcess)]
    param([object]$Identity, [securestring]$NewPassword, [switch]$Reset, [string]$Server)
    Invoke-EobUnmockedStub -Name 'Set-ADAccountPassword'
}
function global:Set-ADAccountExpiration {
    [CmdletBinding(SupportsShouldProcess)]
    param([object]$Identity, [object]$DateTime, [string]$Server)
    Invoke-EobUnmockedStub -Name 'Set-ADAccountExpiration'
}
function global:Get-ADDefaultDomainPasswordPolicy {
    [CmdletBinding()]
    param([object]$Identity, [string]$Server)
    Invoke-EobUnmockedStub -Name 'Get-ADDefaultDomainPasswordPolicy'
}
function global:Get-ADOptionalFeature {
    [CmdletBinding()]
    param([object]$Identity, [string]$Filter, [string]$Server)
    Invoke-EobUnmockedStub -Name 'Get-ADOptionalFeature'
}

# ---------------------------------------------------------------- Exchange
function global:Get-Mailbox {
    [CmdletBinding()]
    param([object]$Identity, [object]$ResultSize)
    Invoke-EobUnmockedStub -Name 'Get-Mailbox'
}
function global:Set-Mailbox {
    [CmdletBinding(SupportsShouldProcess)]
    param([object]$Identity, [string]$Type, [object]$HiddenFromAddressListsEnabled, [string]$ForwardingSmtpAddress,
        [object]$ForwardingAddress, [object]$DeliverToMailboxAndForward)
    Invoke-EobUnmockedStub -Name 'Set-Mailbox'
}
function global:Set-MailboxAutoReplyConfiguration {
    [CmdletBinding(SupportsShouldProcess)]
    param([object]$Identity, [string]$AutoReplyState, [string]$InternalMessage, [string]$ExternalMessage,
        [string]$ExternalAudience, [object]$StartTime, [object]$EndTime)
    Invoke-EobUnmockedStub -Name 'Set-MailboxAutoReplyConfiguration'
}
function global:Get-MailboxPermission {
    [CmdletBinding()]
    param([object]$Identity)
    Invoke-EobUnmockedStub -Name 'Get-MailboxPermission'
}
function global:Get-ConnectionInformation {
    [CmdletBinding()]
    param()
    Invoke-EobUnmockedStub -Name 'Get-ConnectionInformation'
}
function global:Enable-Mailbox {
    [CmdletBinding(SupportsShouldProcess)]
    param([object]$Identity, [string]$Database, [string]$Alias)
    Invoke-EobUnmockedStub -Name 'Enable-Mailbox'
}
function global:Enable-RemoteMailbox {
    [CmdletBinding(SupportsShouldProcess)]
    param([object]$Identity, [string]$RemoteRoutingAddress, [string]$Alias)
    Invoke-EobUnmockedStub -Name 'Enable-RemoteMailbox'
}
function global:Set-RemoteMailbox {
    [CmdletBinding(SupportsShouldProcess)]
    param([object]$Identity, [string]$Type)
    Invoke-EobUnmockedStub -Name 'Set-RemoteMailbox'
}
function global:Connect-ExchangeOnline {
    [CmdletBinding()]
    param([string]$UserPrincipalName, [switch]$ShowBanner, [string]$AppId, [string]$CertificateThumbprint, [string]$Organization)
    Invoke-EobUnmockedStub -Name 'Connect-ExchangeOnline'
}
function global:Disconnect-ExchangeOnline {
    [CmdletBinding(SupportsShouldProcess)]
    param()
    Invoke-EobUnmockedStub -Name 'Disconnect-ExchangeOnline'
}

# Exchange Server im Hybridbetrieb: lokal importierte Befehle mit Präfix 'EobOnPrem'
function global:Get-EobOnPremMailbox {
    [CmdletBinding()]
    param([object]$Identity, [object]$ResultSize)
    Invoke-EobUnmockedStub -Name 'Get-EobOnPremMailbox'
}
function global:Set-EobOnPremMailbox {
    [CmdletBinding(SupportsShouldProcess)]
    param([object]$Identity, [string]$Type, [object]$HiddenFromAddressListsEnabled, [string]$ForwardingSmtpAddress,
        [object]$ForwardingAddress, [object]$DeliverToMailboxAndForward)
    Invoke-EobUnmockedStub -Name 'Set-EobOnPremMailbox'
}
function global:Set-EobOnPremMailboxAutoReplyConfiguration {
    [CmdletBinding(SupportsShouldProcess)]
    param([object]$Identity, [string]$AutoReplyState, [string]$InternalMessage, [string]$ExternalMessage,
        [string]$ExternalAudience, [object]$StartTime, [object]$EndTime)
    Invoke-EobUnmockedStub -Name 'Set-EobOnPremMailboxAutoReplyConfiguration'
}
function global:Get-EobOnPremMailboxPermission {
    [CmdletBinding()]
    param([object]$Identity)
    Invoke-EobUnmockedStub -Name 'Get-EobOnPremMailboxPermission'
}
function global:Enable-EobOnPremRemoteMailbox {
    [CmdletBinding(SupportsShouldProcess)]
    param([object]$Identity, [string]$RemoteRoutingAddress, [string]$Alias)
    Invoke-EobUnmockedStub -Name 'Enable-EobOnPremRemoteMailbox'
}
function global:Set-EobOnPremRemoteMailbox {
    [CmdletBinding(SupportsShouldProcess)]
    param([object]$Identity, [string]$Type)
    Invoke-EobUnmockedStub -Name 'Set-EobOnPremRemoteMailbox'
}

# ---------------------------------------------------------------- Microsoft Graph
function global:Get-MgContext {
    [CmdletBinding()]
    param()
    Invoke-EobUnmockedStub -Name 'Get-MgContext'
}
function global:Revoke-MgUserSignInSession {
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$UserId)
    Invoke-EobUnmockedStub -Name 'Revoke-MgUserSignInSession'
}
function global:Connect-MgGraph {
    [CmdletBinding()]
    param([string[]]$Scopes, [string]$TenantId, [switch]$NoWelcome, [string]$ClientId, [string]$CertificateThumbprint)
    Invoke-EobUnmockedStub -Name 'Connect-MgGraph'
}
function global:Disconnect-MgGraph {
    [CmdletBinding()]
    param()
    Invoke-EobUnmockedStub -Name 'Disconnect-MgGraph'
}

# ---------------------------------------------------------------- Entra Connect (ADSync)
function global:Start-ADSyncSyncCycle {
    [CmdletBinding()]
    param([string]$PolicyType)
    Invoke-EobUnmockedStub -Name 'Start-ADSyncSyncCycle'
}
