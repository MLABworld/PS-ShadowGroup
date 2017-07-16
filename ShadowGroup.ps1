<#
    Created: 10-21-2016
    Last Revision: 7-16-2017
    
    WHAT THIS SCRIPT DOES
    This script evaluates specified OUs and takes any computer object found in each of the
    OUs and makes sure it a member of the a specified AD ShadowGroup.
    
    Updates:
    7-16-17 - MLAB - Hello GitHub! :)
    11-07-16 - MLAB - Added logic to detect invalid OU names. Omits them from  
               searches and adds an error line to the logfile noting their presense.
    12-1-16 - MLAB - Added logic to remove old logfiles
    12-2-16 - Added the $RemoveLimit & $AddLimit variables to avoid accidental bulk adds/deletes.
#>

import-module activedirectory

# Specify a log file
$LogFile = $PSCommandPath + "Log" + (Get-Date -Format "MM-dd-yy_HHmmss") + ".txt"
# Add info to the log file
Add-Content -Path $LogFile -Value "ShadowGroup Powershell Script"
Add-Content -Path $LogFile -Value "Path of running script: $PSCommandPath"
Add-Content -Path $LogFile -Value $("Started: " + (Get-Date).ToString())

# Delete old logfiles
$ScriptPath = $PSScriptRoot
$Daysback = "-10"
$CurrentDate = Get-Date
$DatetoDelete = $CurrentDate.AddDays($Daysback)
Get-ChildItem $ScriptPath -Filter "*Log*.txt" | Where-Object {$_.LastWriteTime -lt $DatetoDelete} | Remove-Item

# Define variables and populate arrays.

# Name of Domain Controller
# Replace <DOMAIN CONTROLLER> with the name of a DC and replace <FQDN OF DOMAIN> with the fully qualified 
# name of the domain you're working with
$Server = "DC01.MLAB.com"
Add-Content -Path $LogFile -Value "DC used for updates: $Server"

# Distinguished Names of the OUs that contain the Computer Objects that are to be added to the Shadow Group
$OUPathnamesToSearch = "OU=SubOU1,OU=ComputerOU1,DC=MLAB,DC=com",
                       "OU=SubOU2,OU=ComputerOU2,DC=MLAB,DC=com",
#                       "OU=SubOU3,OU=ComputerOU2,DC=MLAB,DC=com",
                       "OU=SubOU4,OU=ComputerOU2,DC=MLAB,DC=com"

# Array of OUs to be used as a validated list of production OUs
$OUsForShadowGroup = @()

# Test each OU name in the list a above to be sure it is valid
ForEach ($OUDN in $OUPathnamesToSearch)
{    
       #Check of DN of OU is valid
       $X = [ADSI]"LDAP://$OUDN"
       If ($X.Name)
        {
         # Add the OU to the array of production OUs which will be used for reading computer objects later
         $OUsForShadowGroup = $OUsForShadowGroup + $OUDN
        }
       Else
        {
         # Skip this OU and write an alert in the logfile
         Add-Content -Path $LogFile -Value "*****Error***** OU not found: $OUDN. Removing from the list of OUs to search."
        }
}

# Write this info to the log file
Add-Content -Path $LogFile -Value "Working with the following OUs:"
ForEach ($OU in $OUsForShadowGroup){Add-Content -Path $LogFile -Value $OU}

# Retreive Computer Objects from all OUs mentioned above. Don't retreive disabled computer objects:
$ComputerObjectInOUs = $OUsForShadowGroup | ForEach-Object { Get-ADComputer -Server $server -Filter {(enabled -eq $True)} -SearchBase $_ -SearchScope OneLevel | Select distinguishedName }

# OU path to Shadow Group
# Replace with the Distinguished Name of the Shadow Group
$ShadowGroupDN = "CN=DirectAccess Computers,OU=Groups,DC=MLAB,DC=com"
Add-Content -Path $LogFile -Value "Working with the following ShadowGroup: $ShadowGroupDN"

# Retreive current members of the shadow group
$MembersInGroup = Get-ADComputer -LDAPFilter "(memberOf=$ShadowGroupDN)" `
    -Server $Server | Select distinguishedName, Enabled

# Array of computers to be added to the shadow group
$ComputersToAdd = @()

# Array of computers to be removed from the shadow group
$ComputersToRemove = @()

# Initialize Counters
$RemovedCount = 0
$AddedCount = 0

# Flags if too many users removed or added. 
# Supply a maximum value that should be removed or added at a time 
# to avoid excessive network traffic and long running transactions
# and accidental bulk adds/deletes.
$RemoveLimit = 100
$AddLimit = 100
$TooManyRemoved = $False 
$TooManyAdded = $False 

Add-Content -Path $LogFile -Value "--------------------------------------------------------"
Add-Content -Path $LogFile -Value "----- Discovering Computers for Adds and Removals ------"
Add-Content -Path $LogFile -Value "--------------------------------------------------------"

# Enumerates all existing members of the ShadowGroup and marks 
# any Computers that are disabled for removal from the group
ForEach ($Member in $MembersInGroup)
{
    If ($Member.Enabled -eq $False)
    {
        # Add this member to the array of computers 
        # to be removed from the ShadowGroup
        $ComputersToRemove = $ComputersToRemove + $Member
        $RemovedCount = $RemovedCount + 1
        $ComputerName = $Member.distinguishedName
        Add-Content -Path $LogFile -Value "To be removed from ShadowGroup (disabled): $ComputerName"
    }
    # Check if member is in the OU    
    ElseIf ($ComputerObjectInOUs.distinguishedName -contains $Member.distinguishedName)
                    {
                    # If the computer name was found, don't do anything  
                    }
                Else
                    {
                    # Add this member to the array of computers 
                    # to be removed from the group  
                    $ComputersToRemove = $ComputersToRemove + $Member
                    $RemovedCount = $RemovedCount + 1
                    $ComputerName = $Member.distinguishedName
                    Add-Content -Path $LogFile -Value "To be removed from ShadowGroup (not in OU): $ComputerName"
                    }
    If ($RemovedCount -eq $RemoveLimit)
    {
        $TooManyRemoved = $True
        Break
    }
}

# Enumerates all existing members of the OUs and finds Computers that are
# not members of the ShadowGroup and marks them for addition to the group
ForEach ($ComputerObject in $ComputerObjectInOUs)
{
    If ($MembersInGroup.distinguishedName -contains $ComputerObject.distinguishedName)
                    {
                    # If the computer object is founnd, don't do anything
                    }
                Else
                    {
                    # Add this computer to the array of computers 
                    # to be added to the group
                    $ComputersToAdd = $ComputersToAdd + $ComputerObject
                    $AddedCount = $AddedCount + 1
                    $ComputerName = $ComputerObject.distinguishedName
                    Add-Content -Path $Logfile -Value "To be added to ShadowGroup (new in OU): $ComputerName"
                    }
    If ($AddedCount -eq $AddLimit)
    {
        $TooManyAdded = $True
        Break
    }
}

Add-Content -Path $LogFile -Value "--------------------------------------------------------"
Add-Content -Path $LogFile -Value "---------- Performing Adds and Removals ----------------"
Add-Content -Path $LogFile -Value "--------------------------------------------------------"
# Remove the computers from the ShadowGroup
# first check to be sure there are computers to be removed
If ($ComputersToRemove.Count -gt 0)
{
    # Performs removals from the group
    Remove-ADGroupMember -Identity $ShadowGroupDN -Members $ComputersToRemove -Server $Server -Confirm:$False
    # short pause
    Start-Sleep -Seconds 3
    Add-Content -Path $Logfile -Value " "
    Add-Content -Path $Logfile -Value "Removed the following $RemovedCount Computers from ShadowGroup"
    Add-Content -Path $Logfile -Value "====="
    ForEach ($ComputerName in $ComputersToRemove)
        {
         $Removing = $ComputerName.distinguishedName
         Add-Content -Path $LogFile -Value $Removing
        }
}
Else 
{
    Add-Content -Path $Logfile -Value " "
    Add-Content -Path $Logfile -Value "Nothing to remove from ShadowGroup. Removal count = 0"
    Add-Content -Path $Logfile -Value "====="
}
# Alert if too many removed
If ($TooManyRemoved -eq $True)
{
    Add-Content -Path $LogFile -Value "***** Caution: $RemoveLimit computers removed from the group. This is the maximum allowed." 
    Add-Content -Path $LogFile -Value "Run the script again to process more." 
}


# Add the computers to the ShadowGroup
# first check to be sure there are computers to be added
If ($ComputersToAdd.Count -gt 0)
{
    # Performs additions to the group
    Add-ADGroupMember -Identity $ShadowGroupDN -Members $ComputersToAdd -Server $Server -Confirm:$False
    # short pause
    Start-Sleep -Seconds 3
    Add-Content -Path $Logfile -Value " "
    Add-Content -Path $Logfile -Value "Added the following $AddedCount Computers to ShadowGroup"
    Add-Content -Path $Logfile -Value "====="
    ForEach ($ComputerName in $ComputersToAdd)
        {
         $Adding = $ComputerName.distinguishedName
         Add-Content -Path $LogFile -Value $Adding
        }
}
Else 
{
    Add-Content -Path $Logfile -Value " "
    Add-Content -Path $Logfile -Value "Nothing to add to ShadowGroup. Addition count = 0"
    Add-Content -Path $Logfile -Value "====="
}
# Alert if too many added
If ($TooManyAdded -eq $True)
{
    Add-Content -Path $LogFile -Value "***** Caution: $AddLimit computers added to the group. This is the maximum allowed." 
    Add-Content -Path $LogFile -Value "Run the script again to process more." 
}