<#
.SYNOPSIS
    Builds the Okta Zero Trust Onboarding Lab through the Okta Management API.

.DESCRIPTION
    Automates the same seven phases as the written lab:
      1. Network zone (Corp-Net)
      2. Device assurance policy (Windows 11 only, encryption, TPM; set Windows Hello in the console)
      3. Role-based group (Clinical Staff (Admin))
      4. Users (temporary password, forced change at first sign-in) + scoped Group Administrator
      5. ServiceNow UD app (SAML 2.0): add it once in the Admin Console; the script finds it by
         label and turns on forced re-authentication
      6. Group-to-app assignment (birthright access)
      7. Zero trust app sign-in policy, catch-all set to Deny, applied to ServiceNow

    The script looks each object up by name first, so running it twice does not create duplicates.
    All values below are PLACEHOLDER lab data.

.REQUIREMENTS
    PowerShell 7+
    $env:OKTA_ORG       e.g. https://your-org.okta.com   (no trailing slash)
    $env:OKTA_API_TOKEN an Okta API token (never hard-code it or commit it to GitHub)

.EXAMPLE
    $env:OKTA_ORG = "https://your-org.okta.com"
    $env:OKTA_API_TOKEN = Read-Host "Okta API token" -MaskInput
    ./Build-OktaZeroTrustLab.ps1

.EXAMPLE
    # Separate test build: every object gets a test suffix (e.g. Corp-Net-Test, "(Test)") and users
    # are on clinic-test.com,
    # so the documented lab is never touched.
    ./Build-OktaZeroTrustLab.ps1 -TestRun

.EXAMPLE
    # Remove everything the test build created (only works together with -TestRun).
    ./Build-OktaZeroTrustLab.ps1 -TestRun -Cleanup
#>

[CmdletBinding()]
param(
    [string]$ZoneName        = "Corp-Net",
    [string]$GatewayIp       = "1.2.3.4",        # placeholder
    [string]$ProxyIp         = "192.168.1.1",    # placeholder
    [string]$AssuranceName   = "Clinical Device Assurance (Admin)",
    [string]$MinWindowsBuild = "10.0.22631",     # Windows 11 23H2; any Windows 10 build is lower, so Windows 10 is blocked
    [string]$GroupName       = "Clinical Staff (Admin)",
    [string]$GroupDesc       = "Front - Office",
    [string]$AppLabel        = "ServiceNow UD",
    [string]$AppBaseUrl      = "https://servicenowclinic.com",   # placeholder
    [string]$PolicyName      = "Clinical Group Policy (NO TRUST)",
    [string]$RuleName        = "Clinical Secure Access",
    [string]$UserDomain      = "clinic.com",
    [switch]$TestRun,                            # build a fully separate copy for testing
    [switch]$Cleanup                             # with -TestRun: delete the test copy
)

$ErrorActionPreference = "Stop"
if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw "This script needs PowerShell 7. Type 'pwsh' to switch, set `$env:OKTA_ORG and `$env:OKTA_API_TOKEN again, then rerun."
}

# ---------- Test mode: rename everything so the real lab is never touched ----------
if ($Cleanup -and -not $TestRun) { throw "-Cleanup only works together with -TestRun, so the real lab can never be deleted." }
if ($TestRun) {
    $ZoneName      = "$ZoneName-Test"
    $AssuranceName = "$AssuranceName (Test)"
    $GroupName     = "$GroupName (Test)"
    $GroupDesc     = "Script test group"
    $AppLabel      = "$AppLabel Test"
    $PolicyName    = "$PolicyName (Test)"
    $RuleName      = "$RuleName (Test)"
    $UserDomain    = "clinic-test.com"
    Write-Host "TEST RUN: all objects use test names; users are on $UserDomain" -ForegroundColor Yellow
}

# ---------- Connection ----------
if (-not $env:OKTA_ORG -or -not $env:OKTA_API_TOKEN) {
    throw "Set `$env:OKTA_ORG and `$env:OKTA_API_TOKEN before running."
}
$Org     = $env:OKTA_ORG.TrimEnd("/")
$Headers = @{
    Authorization = "SSWS $($env:OKTA_API_TOKEN)"
    Accept        = "application/json"
}

function Invoke-Okta {
    param(
        [ValidateSet("GET","POST","PUT","DELETE")] [string]$Method,
        [string]$Path,
        $Body
    )
    $params = @{ Method = $Method; Uri = "$Org$Path"; Headers = $Headers; ContentType = "application/json" }
    if ($null -ne $Body) { $params.Body = ($Body | ConvertTo-Json -Depth 20) }
    try {
        # Assign then output: this unrolls JSON arrays into separate items on every
        # PowerShell version (Windows PowerShell 5.1 otherwise passes a list as ONE object).
        $result = Invoke-RestMethod @params
        $result
    } catch {
        $detail = $_.ErrorDetails.Message
        throw "Okta API $Method $Path failed: $($_.Exception.Message) $detail"
    }
}

function Write-Step($text) { Write-Host "`n==> $text" -ForegroundColor Cyan }
function Write-Ok($text)   { Write-Host "    [OK] $text" -ForegroundColor Green }

# Lab users (placeholder data)
$Users = @(
    @{ First = "Nelly"; Last = "Smith"; Login = "nsmith@$UserDomain" },
    @{ First = "John";  Last = "Doe";   Login = "jdoe@$UserDomain"   },
    @{ First = "Jane";  Last = "Zoe";   Login = "jzoe@$UserDomain"   }
)
$GroupAdminLogin = "nsmith@$UserDomain"     # the delegated group admin

# ---------- Cleanup of the test copy ----------
if ($Cleanup) {
    Write-Step "Cleanup: removing test objects"
    function Find-ByName($list, $prop, $value) { $list | Where-Object { $_.$prop -eq $value } | Select-Object -First 1 }

    foreach ($u in $Users) {
        try {
            $usr = Invoke-Okta GET "/api/v1/users/$([uri]::EscapeDataString($u.Login))"
            if ($usr.status -ne "DEPROVISIONED") { Invoke-Okta POST "/api/v1/users/$($usr.id)/lifecycle/deactivate" | Out-Null }
            Invoke-Okta DELETE "/api/v1/users/$($usr.id)" | Out-Null
            Write-Ok "Deleted user $($u.Login)"
        } catch { Write-Host "    [skip] user $($u.Login) not found" }
    }
    $pol = Find-ByName (Invoke-Okta GET "/api/v1/policies?type=ACCESS_POLICY") "name" $PolicyName
    $app = (Invoke-Okta GET "/api/v1/apps?limit=200") | Where-Object { $_.label.Trim() -ieq $AppLabel.Trim() } | Select-Object -First 1
    if ($app) {
        if ($app.status -eq "ACTIVE") { Invoke-Okta POST "/api/v1/apps/$($app.id)/lifecycle/deactivate" | Out-Null }
        Invoke-Okta DELETE "/api/v1/apps/$($app.id)" | Out-Null; Write-Ok "Deleted app $AppLabel"
    }
    if ($pol) { Invoke-Okta DELETE "/api/v1/policies/$($pol.id)" | Out-Null; Write-Ok "Deleted policy $PolicyName" }
    $grp = (Invoke-Okta GET "/api/v1/groups?q=$([uri]::EscapeDataString($GroupName))") | Where-Object { $_.profile.name -eq $GroupName } | Select-Object -First 1
    if ($grp) { Invoke-Okta DELETE "/api/v1/groups/$($grp.id)" | Out-Null; Write-Ok "Deleted group $GroupName" }
    $da = Find-ByName (Invoke-Okta GET "/api/v1/device-assurances") "name" $AssuranceName
    if ($da) { Invoke-Okta DELETE "/api/v1/device-assurances/$($da.id)" | Out-Null; Write-Ok "Deleted device assurance $AssuranceName" }
    $zn = (Invoke-Okta GET "/api/v1/zones") | Where-Object { $_.name -eq $ZoneName } | Select-Object -First 1
    if ($zn) {
        if ($zn.status -eq "ACTIVE") { Invoke-Okta POST "/api/v1/zones/$($zn.id)/lifecycle/deactivate" | Out-Null }
        Invoke-Okta DELETE "/api/v1/zones/$($zn.id)" | Out-Null; Write-Ok "Deleted zone $ZoneName"
    }
    Write-Host "`nTest copy removed." -ForegroundColor Green
    return
}

# ---------- Phase 1: Network zone ----------
Write-Step "Phase 1: Network zone '$ZoneName'"
$zone = (Invoke-Okta GET "/api/v1/zones") | Where-Object { $_.name -eq $ZoneName -and $_.type -eq "IP" } | Select-Object -First 1
if (-not $zone) {
    $zone = Invoke-Okta POST "/api/v1/zones" @{
        type      = "IP"
        name      = $ZoneName
        gateways  = @(@{ type = "RANGE"; value = "$GatewayIp-$GatewayIp" })
        proxies   = @(@{ type = "RANGE"; value = "$ProxyIp-$ProxyIp" })
    }
}
Write-Ok "Zone id $($zone.id)"

# ---------- Phase 2: Device assurance policy ----------
Write-Step "Phase 2: Device assurance policy '$AssuranceName'"
$da = (Invoke-Okta GET "/api/v1/device-assurances") | Where-Object { $_.name -eq $AssuranceName } | Select-Object -First 1
if (-not $da) {
    $da = Invoke-Okta POST "/api/v1/device-assurances" @{
        name                  = $AssuranceName
        platform              = "WINDOWS"
        osVersion             = @{ minimum = $MinWindowsBuild }
        diskEncryptionType    = @{ include = @("ALL_INTERNAL_VOLUMES") }
        secureHardwarePresent = $true          # Trusted Platform Module (TPM)
        # Windows Hello requirement: confirm the API field for your org in the
        # Device Assurance API docs, or set it in the Admin Console afterwards.
    }
}
Write-Ok "Device assurance id $($da.id)"

# ---------- Phase 3: Role-based group ----------
Write-Step "Phase 3: Group '$GroupName'"
$encodedGroup = [uri]::EscapeDataString($GroupName)
$group = (Invoke-Okta GET "/api/v1/groups?q=$encodedGroup") | Where-Object { $_.profile.name -eq $GroupName } | Select-Object -First 1
if (-not $group) {
    $group = Invoke-Okta POST "/api/v1/groups" @{ profile = @{ name = $GroupName; description = $GroupDesc } }
}
Write-Ok "Group id $($group.id)"

# ---------- Phase 4: Users + scoped group admin ----------
Write-Step "Phase 4: Users"
$createdUsers = @{}
foreach ($u in $Users) {
    $existing = $null
    try { $existing = Invoke-Okta GET "/api/v1/users/$([uri]::EscapeDataString($u.Login))" } catch { }
    if ($existing) {
        # Make sure an existing user is in the group
        Invoke-Okta PUT "/api/v1/groups/$($group.id)/users/$($existing.id)" | Out-Null
        $createdUsers[$u.Login] = $existing
        Write-Ok "$($u.Login) already exists; confirmed in group"
        continue
    }
    # Temporary one-time password; the user must change it at first sign-in
    $tempPassword = "Tmp-" + [guid]::NewGuid().ToString("N").Substring(0,12) + "!9a"
    $user = Invoke-Okta POST "/api/v1/users?activate=true&nextLogin=changePassword" @{
        profile     = @{ firstName = $u.First; lastName = $u.Last; email = $u.Login; login = $u.Login }
        credentials = @{ password = @{ value = $tempPassword } }
        groupIds    = @($group.id)
    }
    $createdUsers[$u.Login] = $user
    Write-Ok "$($u.Login) created. Temporary password (share securely, shown once): $tempPassword"
}

Write-Step "Phase 4: Group Administrator for $GroupAdminLogin, scoped to '$GroupName'"
$admin = $createdUsers[$GroupAdminLogin]
$roles = Invoke-Okta GET "/api/v1/users/$($admin.id)/roles"
$role  = $roles | Where-Object { $_.type -eq "USER_ADMIN" } | Select-Object -First 1   # USER_ADMIN = Group Administrator
if (-not $role) {
    $role = Invoke-Okta POST "/api/v1/users/$($admin.id)/roles" @{ type = "USER_ADMIN" }
}
# Constrain the role to the one group (not the entire organization)
Invoke-Okta PUT "/api/v1/users/$($admin.id)/roles/$($role.id)/targets/groups/$($group.id)" | Out-Null
Write-Ok "Role $($role.id) constrained to group $($group.id)"

# ---------- Phase 5: ServiceNow UD with SAML 2.0 ----------
Write-Step "Phase 5: App '$AppLabel' (SAML 2.0)"
$allApps = Invoke-Okta GET "/api/v1/apps?limit=200"
$app = $allApps | Where-Object { $_.label.Trim() -ieq $AppLabel.Trim() } | Select-Object -First 1
if (-not $app) {
    $labels = ($allApps | ForEach-Object { "      - $($_.label)" }) -join "`n"
    throw @"
No app labeled '$AppLabel' was found.
Catalog apps like ServiceNow UD must be added once in the Admin Console:
  Applications > Applications > Browse App Catalog > ServiceNow UD > Add Integration
  Application label: $AppLabel   (exact spelling), select SAML 2.0, click Done.
Then run the script again. Apps currently in your org:
$labels
"@
}
if ($app.status -ne "ACTIVE") { Invoke-Okta POST "/api/v1/apps/$($app.id)/lifecycle/activate" | Out-Null }
# Honor ServiceNow's force-authentication requests (= "Disable Force Authentication" UNCHECKED)
$app = Invoke-Okta GET "/api/v1/apps/$($app.id)"      # full app object, not the list summary
$forceAuthnOk = $false
if ($null -ne $app.settings.signOn) {
    try {
        $app.settings.signOn | Add-Member -NotePropertyName honorForceAuthn -NotePropertyValue $true -Force
        $app = Invoke-Okta PUT "/api/v1/apps/$($app.id)" $app
        $forceAuthnOk = [bool]$app.settings.signOn.honorForceAuthn
    } catch {
        Write-Warning "Could not update force authentication through the API: $($_.Exception.Message)"
    }
}
if ($forceAuthnOk) {
    Write-Ok "App id $($app.id), signOnMode $($app.signOnMode), force authentication honored"
} else {
    Write-Warning "Set this one by hand: $AppLabel > Sign On > Edit > UNCHECK 'Disable Force Authentication' > Save. Continuing with the rest of the build."
}

# ---------- Phase 6: Assign the group to the app ----------
Write-Step "Phase 6: Assign '$GroupName' to '$AppLabel'"
Invoke-Okta PUT "/api/v1/apps/$($app.id)/groups/$($group.id)" @{} | Out-Null
Write-Ok "Group assigned (birthright access)"

# ---------- Phase 7: Zero trust app sign-in policy ----------
Write-Step "Phase 7: Authentication policy '$PolicyName'"
$policy = (Invoke-Okta GET "/api/v1/policies?type=ACCESS_POLICY") | Where-Object { $_.name -eq $PolicyName } | Select-Object -First 1
if (-not $policy) {
    $policy = Invoke-Okta POST "/api/v1/policies" @{
        type        = "ACCESS_POLICY"
        name        = $PolicyName
        description = "This policy will define the appropriate rules required to authenticate into an application."
    }
}
Write-Ok "Policy id $($policy.id)"

$rules = Invoke-Okta GET "/api/v1/policies/$($policy.id)/rules"
$ruleBody = @{
    type       = "ACCESS_POLICY"
    name       = $RuleName
    priority   = 1
    conditions = @{
        people  = @{ groups = @{ include = @($group.id) } }
        network = @{ connection = "ZONE"; include = @($zone.id) }
        device  = @{
            registered = $true
            managed    = $true
            assurance  = @{ include = @($da.id) }
        }
    }
    actions = @{
        appSignOn = @{
            access             = "ALLOW"
            verificationMethod = @{
                type             = "ASSURANCE"
                factorMode       = "2FA"
                reauthenticateIn = "PT0S"      # every time the user signs in to the resource
                constraints      = @(@{
                    possession = @{
                        phishingResistant = "REQUIRED"
                        userPresence      = "REQUIRED"
                        userVerification  = "REQUIRED"   # biometric user verification
                    }
                })
            }
        }
    }
}
$rule = $rules | Where-Object { $_.name -eq $RuleName } | Select-Object -First 1
if ($rule) {
    $rule = Invoke-Okta PUT "/api/v1/policies/$($policy.id)/rules/$($rule.id)" $ruleBody
} else {
    $rule = Invoke-Okta POST "/api/v1/policies/$($policy.id)/rules" $ruleBody
}
Write-Ok "Rule '$RuleName' id $($rule.id)"

# Lock down the catch-all rule (default-deny)
$catchAll = $rules | Where-Object { $_.system -eq $true -or $_.name -eq "Catch-all Rule" } | Select-Object -First 1
if ($catchAll) {
    $catchAll.actions.appSignOn.access = "DENY"
    Invoke-Okta PUT "/api/v1/policies/$($policy.id)/rules/$($catchAll.id)" $catchAll | Out-Null
    Write-Ok "Catch-all rule set to DENY"
} else {
    Write-Warning "Catch-all rule not found; set it to Denied in the Admin Console."
}

# Apply the policy to ServiceNow
Invoke-Okta PUT "/api/v1/apps/$($app.id)/policies/$($policy.id)" | Out-Null
Write-Ok "Policy applied to $AppLabel"

# ---------- Verification ----------
Write-Step "Verification"
$assigned = Invoke-Okta GET "/api/v1/apps/$($app.id)/groups"
$check = [ordered]@{
    "Group assigned to app"      = [bool]($assigned | Where-Object { $_.id -eq $group.id })
    "Users in group"             = @(Invoke-Okta GET "/api/v1/groups/$($group.id)/users").Count
    "Admin role scoped to group" = [bool](Invoke-Okta GET "/api/v1/users/$($admin.id)/roles/$($role.id)/targets/groups" | Where-Object { $_.id -eq $group.id })
    "Force authn honored"        = $forceAuthnOk
    "Catch-all denies"           = ((Invoke-Okta GET "/api/v1/policies/$($policy.id)/rules") | Where-Object { $_.system -eq $true }).actions.appSignOn.access -eq "DENY"
}
$check.GetEnumerator() | ForEach-Object { "{0,-28} {1}" -f $_.Key, $_.Value } | Write-Host
Write-Host "`nDone. Review the configuration in the Admin Console and System Log." -ForegroundColor Green
