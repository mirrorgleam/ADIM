#############################################################################
#        UPDATE ALL VALUES BETWEEN THESE LINES


# Path to save and read from for CSV and HTML files
$csv_path = "C:\Path to where you want to store your last AD record\file.csv"
$html_path = "C:\Path to where you want to save your html formatted report\file.htm"

# Parameters to be used if there were changes to AD
$Mail_Parms_Change = @{
'To' = 'Destination@Domain.TLD' ;
'From' = 'Source@Domain.TLD' ;
'Subject' = 'Active Directory Integrity Monitoring' ;
'Body' = $html_body ;
'BodyAsHTML' = $true ;
'Attachments' = $csv_path, $html_path ;
'credential' = Get-Credential ;
'SmtpServer' = 'yourServer.Domain.TLD'}

# Parameters to be used if there were no changes to AD
$Mail_Parms_NoChange = @{
'To' = 'Destination@Domain.TLD' ;
'From' = 'Source@Domain.TLD' ;
'Subject' = 'Active Directory Integrity Monitoring - No Change' ;
'Body' = "Nothing to report`nAlive check" ;
'credential' = Get-Credential ;
'SmtpServer' = 'yourServer.Domain.TLD'}


#        UPDATE ALL VALUES BETWEEN THESE LINES
#############################################################################

#region Building Objects for Current AD and Previous AD

function Get-AdminSecGroups ($Obj)
# Format and filter AD Security Groups for clarity
{
    $Obj."MemberOf" |ForEach-Object {
        if ($_ -match 'OU=Security Groups') {
            $Group_Name += @($_.Split(",")[0].Split("=")[1])
        }
    }
    if ($Group_Name -ne $null) {
        return $Group_Name -join(" ; ")
    }
    else {
        return ''
    }
}


# Test to see if csv_path exists. 
# Should only run the first time you use this script
if (!(Test-Path $csv_path)) {
    Get-ADUser -Properties ObjectGUID, mail, enabled, DisplayName, samaccountname, created, MemberOf -Filter * |
        Select -Property ObjectGUID, mail, enabled, DisplayName, samaccountname, created, MemberOf |
        ForEach-Object {$_.MemberOf = Get-AdminSecGroups $_ ; $_} |Sort -Property created |
        Export-Csv -Path $csv_path -NoTypeInformation
}


# Build object from last AD check
$Previous_CSV = Import-Csv -Path $CSV_Path |
    ForEach-Object {$_.created = $_.created -as [datetime]; $_ } |
    Sort -Property created


# Build object from current AD info
$Recent_AD = Get-ADUser -Properties ObjectGUID, mail, enabled, DisplayName, samaccountname, created, MemberOf -Filter * |
    Select -Property ObjectGUID, mail, enabled, DisplayName, samaccountname, created, MemberOf |
    ForEach-Object {$_.MemberOf = Get-AdminSecGroups $_  ; $_} |
    ForEach-Object {$_.enabled = $_.enabled -as [string] ; $_} |
    Sort -Property created

#endregion


#region Check for changes to AD

# Check for new entries in AD
$New_Accounts = Compare-Object -ReferenceObject $Previous_CSV -DifferenceObject $Recent_AD -Property ObjectGUID -PassThru -SyncWindow $($Recent_AD.Count / 2) |?{$_.SideIndicator -eq '=>'}

# Check for entries with changes to enabled status
$Changed_Enabled = Compare-Object -ReferenceObject $Previous_CSV -DifferenceObject $Recent_AD -Property ObjectGUID, enabled -PassThru -SyncWindow $($Recent_AD.Count / 2) |?{$_.SideIndicator -eq '<='}

# Check for changes in Admin Security Group membership
$Changed_MemberOf = Compare-Object -ReferenceObject $Previous_CSV -DifferenceObject $Recent_AD -Property ObjectGUID, MemberOf -SyncWindow $($Recent_AD.Count / 2) |?{$_.SideIndicator -eq '<='}

$Final_MemberOf = @()
foreach ($entry in $Changed_MemberOf) {
    $Old_MemberOf = ($Previous_CSV -match $entry.ObjectGUID |select -ExpandProperty MemberOf) -split(" ; ")
    $New_MemberOf = ($Recent_AD -match $entry.ObjectGUID |select -ExpandProperty MemberOf) -split(" ; ")

    $temp_obj = New-Object psobject -Property @{
        DisplayName = $Previous_CSV -match $entry.ObjectGUID |select -ExpandProperty DisplayName
        New_MemberOf = (Compare-Object $Old_MemberOf $New_MemberOf -PassThru |where {$_.SideIndicator -eq '=>'}) -join(" ; ")
    }
    if ($temp_obj.New_MemberOf -ne '') {
        $Final_MemberOf += $temp_obj
    }
}

#endregion


#region if changes found: update CSV and send email

if ($Changed_Enabled.count -gt 0 -or $New_Accounts.count -gt 0 -or $Final_MemberOf.count -gt 0)
{
# Update CSV with latest AD info
$Recent_AD |Select -Property ObjectGUID, mail, enabled, DisplayName, samaccountname, created, MemberOf |Export-Csv -Path $csv_path -NoTypeInformation


# Build and send email with updated info
$html_head = '<style>'
$html_head += 'BODY{background-color:#ffffff; }'
$html_head += 'TABLE{border-width: 1px;border-style: solid;border-color: black;border-collapse: collapse;}'
$html_head += 'TH{border-width: 1px;padding: 5px;border-style: solid;border-color: black;background-color: lightblue}'
$html_head += 'TD{border-width: 1px;padding: 5px 10px;border-style: solid;border-color: black;}'
$html_head += 'TR:nth-child(odd) {background-color: lightgray}'
$html_head += '</style>'


$New_Accounts_html = $New_Accounts |select `
@{Name="Full Name";Expression={$_.DisplayName}},`
@{Name="User Name";Expression={$_.samaccountname}},`
@{Name="E-Mail";Expression={$_.mail}},`
@{Name="Created On";Expression={$_.created}}|
ConvertTo-HTML -Head $html_head -Body "<H2>Total New Entries: $($New_Accounts.count)</H2>" -PostContent "<br><br><br><br>" | out-string

$Changed_MemberOf_html = $Final_MemberOf |select `
@{Name="Full Name";Expression={$_.DisplayName}},`
@{Name="Added To Admin Group";Expression={$_.New_MemberOf}}|
ConvertTo-HTML -Head $html_head -Body "<H2>Total New Admins: $($Final_MemberOf.count)</H2>" -PostContent "<br><br><br><br>" | out-string

$changed_enabled_html = $changed_enabled |select `
@{Name="Full Name";Expression={$_.DisplayName}},`
@{Name="User Name";Expression={$_.samaccountname}},`
@{Name="Old Status";Expression={$_.enabled}},`
@{Name="New Status";Expression={if ($_.enabled -eq "True") {"FALSE"} else {"TRUE"}}}|
ConvertTo-HTML -Head $html_head -Body "<H2>Total Changed Entries: $($changed_enabled.count)</H2>" -PostContent "<br><br><i>Tables created on: $(Get-Date)" | out-string


$html_body = $New_Accounts_html + $Changed_MemberOf_html + $Changed_enabled_html

$html_body |Out-String > $html_path

# Send email with recent changes
Send-MailMessage @Mail_Parms_Change

}

else # Optional - send email stating that nothing was found but script is still alive
{

Send-MailMessage @Mail_Parms_NoChange

}

#endregion

