<#
    Enable-Auditing.ps1  --  run on the domain controller as Domain Admin, after promotion.

    Turns on the Advanced Audit Policy subcategories the Wazuh AD rules need (ad_rules.xml),
    and adds the SACL on the domain object that makes DCSync (4662) auditable. Lab use only.

    After this, confirm events appear under Event Viewer > Security, then let the Wazuh agent ship them.
#>
[CmdletBinding()] param()
$ErrorActionPreference = 'Stop'

Write-Host '== Advanced Audit Policy ==' -ForegroundColor Cyan
$subs = @(
    'Kerberos Authentication Service',      # 4768, 4771  (AS-REP roasting, RC4 TGT)
    'Kerberos Service Ticket Operations',   # 4769, 4770  (Kerberoasting)
    'Directory Service Access',             # 4662        (DCSync)
    'Logon',                                # 4624, 4625  (Pass-the-Hash, lateral movement)
    'Security Group Management'             # 4728/4732/4756 (privileged group changes)
)
foreach ($s in $subs) {
    auditpol /set /subcategory:"$s" /success:enable /failure:enable | Out-Null
    Write-Host "  enabled: $s"
}

Write-Host '== SACL on the domain object for DCSync (4662) ==' -ForegroundColor Cyan
Import-Module ActiveDirectory
$domainDN = (Get-ADDomain).DistinguishedName
$path     = "AD:\$domainDN"
# DS-Replication-Get-Changes and DS-Replication-Get-Changes-All
$replGuids = @('1131f6aa-9c07-11d1-f79f-00c04fc2dcd2', '1131f6ad-9c07-11d1-f79f-00c04fc2dcd2')
$everyone  = New-Object System.Security.Principal.SecurityIdentifier 'S-1-1-0'

$acl = Get-Acl -Path $path -Audit
foreach ($g in $replGuids) {
    $rule = New-Object System.DirectoryServices.ActiveDirectoryAuditRule(
        $everyone,
        [System.DirectoryServices.ActiveDirectoryRights]::ExtendedRight,
        [System.Security.AccessControl.AuditFlags]::Success,
        [Guid]$g)
    $acl.AddAuditRule($rule)
}
Set-Acl -Path $path -AclObject $acl
Write-Host "  audit ACEs added on $domainDN"

Write-Host 'Done. Verify with: auditpol /get /category:* | findstr /i "kerberos directory logon group"' -ForegroundColor Green
