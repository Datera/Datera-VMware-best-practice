<#
         Morae/Datera VMware Best Practices Implementation Script

=====================================================================
|                          Disclaimer:                              |
| This scripts are offered "as is" with no warranty.  While this    |
| scripts is tested and working in my environment, it is            |
| recommended that you test this script in a test lab before using  |
| in a production environment. Everyone can use the scripts/commands|
| provided here without any written permission but I will not be    |
| liable for any damage or loss to the system.                      |
=====================================================================

Requirements:
1. PowerCLI connection to a Windows vCenter server that manages
   ESXi hosts that must have privileges to make changes to advanced
   settings
2. Before running, if you want to modify the configurations based on
   the this script, please make sure the ESXi hosts not connected
   to iSCSI target.
#>


########
########  Parameters Section
########

Param(
[parameter(Mandatory=$false, HelpMessage="
     !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
     !!  The script is used to disable ATS heartbeat and    !!
     !!  to change 3 iSCSI parameters globally on new       !!
     !!  ESXi hosts without datastore/storage.              !!
     !!    - Disable ATS Heartbeat                          !!
     !!    - Disable DelayedAck on software iSCSI adapter   !!
     !!    - Set iSCSI queue depth to 16                    !!
     !!    - Set Datera NMP SATP Rule to                    !!
     !!      VMW_PSP_RR and IOPS = 1                        !!
     !!                                                     !!
     !!  This may cause mis-function on ESXi hosts          !!
     !!  If you have sorage connected, it is your risk      !!
     !!  to update configuration of software iSCSI adapter  !!
     !!  via this script.                                   !!
     !!                                                     !!
     !!  This script is offered `"as is`" with no warranty. !!
     !!  I will not be liable for any damage or loss to     !!
     !!  the system if you run this script. You need to     !!
     !!  test on your platform and understand the script.   !!
     !!                                                     !!
     !!  If you agree to proceed, please enter `"Yes`" to   !!
     !!  update; otherwise enter `"No`" to only display     !!
     !!  the current setup.                                 !!
     !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
")] [bool]$Update=$false,
[parameter(Mandatory=$true,HelpMessage="
    This is the FQDN of the vCenter Server
    E.g. vcenter.example.com
")] [string] $vCenterServer,
[parameter(Mandatory=$false,HelpMessage="
    When set to true means script output tells user everything
    that is happening throughout the script.
    If you want lighter feedback, enable the succinct flag.
")][bool] $verb = $false,
   [parameter(Mandatory=$false,HelpMessage="
    When set to true means the script will give you summary
    output throughout the script.
    If you want more feedback, try the verbose flag.
")][bool] $succinct = $false,
[parameter(Mandatory=$true,HelpMessage="
    This is the account that you will use to connect to vCenter")]
    [PSCredential] $vCredential,
[parameter(Mandatory=$false,HelpMessage="
    Use this to keep from sending an email on each run of the script.  Great for debugging and fixing existing problem machines.
")] [bool] $SendEmail=$false,
[parameter(Mandatory=$false,HelpMessage="
    !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
    !!                                                       !!
    !!                     #WARNING#                         !!
    !!  If set to true this script could disrupt a           !!
    !!  production environment. Proceed with caution.        !!
    !!                                                       !!
    !!  Setting this flag will force the system to ignore    !!
    !!  built-in logic checks but end up setting the correct !!
    !!  values to make the system optimal.                   !!
    !!                                                       !!
    !!  By setting this flag you acknowledge this risk and   !!
    !!  do so against best-practice. You have read and       !!
    !!  understood the documentation.  This SHOULD work for  !!
    !!  most, but some may do harm to their environemnt.     !!
    !!                                                       !!
    !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
")] [bool]$iWantToLiveDangerously=$false)


########
########  Include constants and helper functions
########

 . "$PSScriptRoot\constants.ps1"
 . "$PSScriptRoot\helper.ps1"


#######################################################
#######################################################
################### SCRIPT START ######################
#######################################################
#######################################################

Write-Host "

                .I%%%%7.
              ~%%%%%%%%%%=.
          .,%%%%%%%%7%%%%%%%.
       ..%%%%%%%%%%%  ..%%%%%%%..
    ..7%%%%%%%%%%%%%     .:%%%%%%%.
   .%%%%%%%%%%%%%%%%        .?%%%%%%
   %%%%%%%%%%%%%%%%%           .%%%%%
  .%%%%%%%%%%%%%%%%%             .%%%.
  .%%%%%%%%%%%%%%%%%             .%%%.
  .%%%%%%%%%%%%%%%%%             .%%%.
  .%%%%%%%%%%%%%%%%%             .%%%.
  .%%%%%%%%%%%%%%%%%             .%%%.
  .%%%%%%%%%%%%%%%%%             .%%%.
  .%%%%%%%%%%%%%%%%%             .%%%.
  .%%%%%%%%%%%%%%%%%             .%%%.
  .%%%%%%%%%%%%%%%%%            .%%%%.
   ,%%%%%%%%%%%%%%%%         .%%%%%%~
    .:%%%%%%%%%%%%%%      .I%%%%%%~.
        I%%%%%%%%%%%    .%%%%%%I.
          .%%%%%%%%% .%%%%%%%.
            ..%%%%%%%%%%%%..
               .,%%%%%%:.
                  ..~,.

       SOFTWARE DEFINED STORAGE
       " -ForegroundColor Cyan
Write-Host "      Datera® VMware® Best Practices
          Configuration Script
          "
$verbose = $verb

#$vCenterServer = "view-vcenter.clutchgroup.infra"
if ($vCredential -eq $null)
{
    $vCredential = Get-Credential -Message "$vCenterServer"
}


Write-Host "Connecting to vCenter..."
$list = Connect-VIServer $vCenterServer -Credential $vCredential -Force
if ($list -eq $null){
    Write-Host "Could not connect to vCenter at $vCenterServer." -ForegroundColor Red
    return
}

$vCenter = $global:DefaultVIServer

Write-Host -ForegroundColor Green "Successfully connected to $($vCenter.Name) as $($vCenter.User)."


## Before you run this script, you have to make sure all ESXi hosts
## must be actively managed by vCenter server.
$vmhosts = Get-VMhost

####
## Setup our results table for output
####

$results = $vmhosts | Select-Object Name

$results | add-member -MemberType NoteProperty -Name Connection_State -Value NotSet
$results | add-member -MemberType NoteProperty -Name Reboot_Required -Value No
$results | add-member -MemberType NoteProperty -Name Found_ATS_HB -Value NotSet
$results | add-member -MemberType NoteProperty -Name Found_Queue_Depth -Value NotSet
$results | add-member -MemberType NoteProperty -Name Found_Delayed_Ack -Value NoAdaptorPresent
$results | add-member -MemberType NoteProperty -Name Found_NMP_SATP_Rule -Value NotSet
$results | add-member -MemberType NoteProperty -Name Opt_Status -Value Unknown

########
########   SCRIPT START
########


$safeHosts = @()
if($verbose -eq $true){
    Write-Host ("====== List current ESXi hosts managed by vCenter ======")
    $vmhosts
    Write-Host (" ")
}

# If we are updating...
if ($Update -eq $true) {
    # Warning
    if ($verbose -or $succinct){
         Write-Host "
    !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
    !!                                                       !!
    !! This part of the script does not run on the ESXi      !!
    !! hosts that have iSCSI targets or are not in           !!
    !! maintenance mode in case you run this script by       !!
    !! mistake                                               !!
    !!                                                       !!" -ForegroundColor Green
Write-Host -ForegroundColor Red "    !!                     #WARNING#                         !!
    !!  Running this section could disrupt a production      !!
    !!  environment. Proceed with caution.                   !!"
Write-Host -ForegroundColor Green "    !!                                                       !!
    !! You can:                                              !!
    !! 1.  Remove iSCSI targets from dynamic discovery and   !!
    !!     static target, removing the iSCSI targets will    !!
    !!     cause your ESXi datastore misfunction. You need   !!
    !!     to know what you're doing and risks               !!
    !!     Re-run this script again after removing them      !!
    !!                                                       !!
    !! 2.  If you really want to run this script despite     !!
    !!     this safety check, you can acknowledge this risk  !!
    !!     by adding a switch at runtime to show that you    !!
    !!     have read the documentation and understand that   !!
    !!     this script may due harm to your environemnt.     !!"
Write-Host -ForegroundColor Red "    !!                                                       !!
    !!           -iWantToLiveDangerously:`$true               !!
    !!                                                       !!"
Write-Host -ForegroundColor Green "    !! If you are seeing this message despite entering this  !!
    !! switch, you would know that the script will pause     !!
    !! here for 20 seconds just in case you didn't want to   !!
    !! to run the script and did so by accident              !!
    !!                                                       !!
    !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

    "
}

    Write-Host "Sleeping 20 seconds..."
    Start-Sleep -Seconds 20

    # Determine which hosts are safe
    if ($verbose -or $succinct){Write-Host "
Determining which hosts are safe to update."}
    foreach($esx in $vmhosts){


        if ($succinct)
        { Write-Host "Checking $($esx.name)..."}
        if ($esx.ConnectionState -eq "Maintenance" -or $iWantToLiveDangerously)
        {
            $safeHosts += $esx
            if ($verbose) {Write-Host "$($esx.name) is in Maintenance or you want to live dangerously"}
            continue
        }
        if ($verbose) {Write-Host "$($esx.name) is not in Maintenance Mode. Checking iSCSI Adapters..."}
        $IscsiHba = $esx | Get-VMHostHba -Type iScsi | Where {$_.Model -eq "iSCSI Software Adapter"}
        if ($IscsiHba -eq $null)
        {
            $safeHosts += $esx
            if ($verbose) {Write-Host "$($esx.name) has no iSCSI adapter, it's safe, but need to configure manually" -ForegroundColor Yellow}
            continue
        }
        $IscsiTarget = Get-IScsiHbaTarget -IScsiHba $IscsiHba
        if ($IscsiTarget -eq $null) {
            $safeHosts += $esx
            if ($verbose) {Write-Host "$($esx.name) has no targets. Adding to safe list" -ForegroundColor Yellow}
        }
        else
        {
            if ($verbose) {Write-Host "iSCSI Targets found, $($esx.Name) is unsafe."}
        }

    }
    if ($succinct) {Write-Host "Identified $($safehosts.Count) hosts available to update."}
}

if ($verbose -or $succinct) {
    Write-Host "This script will:
 - Disable ATS heartbeat on all ESXi hosts, otherwise iSCSI will misfunction
 - Set up iSCSI Queue Depth to be optimal per recommendation
 - Turn Off DelayedAck for improved performance in virtual Workloads
 - Set the NMP SATP Rule for optimal default datastore creation
"
}


if ($verbose -eq $true) {
Write-Host -ForegroundColor Green "

########
######## Looping through all ESXi hosts
########

"
}

foreach ($esx in $vmhosts)
{
    $index = $vmhosts.IndexOf($esx)
    $results.Item($index).Connection_State = $esx.ConnectionState
    if ($esx.ConnectionState -ne "NotResponding"){
        $results.Item($index).Opt_Status = "Optimal"
        if ($verbose -eq $true -or $succinct -eq $true){
            Write-Host ("########## " + $esx.Name + " ##########") -ForegroundColor Magenta
            Write-Host ("  ")
        }


########
########    Item 1: ATS heartbeat
########
##    Disable ATS Heartbeat on each ESXi host
##    Alternate method of implementation:
##        esxcli system settings advanced set -i 0 -o /VMFS3/UseATSForHBOnVMFS5
##
##    For details, please refer to https://kb.vmware.com/s/article/2113956#>
########

        if ($verbose) {Write-Output ("==== ATS heartbeat on " + $esx.Name + " (1:enabled 0:disabled) " + " ====")}
        $setting = Get-AdvancedSetting -Entity $esx -Name VMFS3.UseATSForHBOnVMFS5
        $results.Item($index).Found_ATS_HB = $setting.Value
        if ($verbose)
        {
            $setting | Format-List | Format-Color @{"Value\s*:\s*1$" = 'Red'; "Value\s*:\s*0" = 'Green'}
        }
        if ($setting.value -eq 1)
        {
            if ($succinct) {Write-Host -ForegroundColor Red "DANGER: ATS For Heartbeat is On."}
            $results.Item($index).Opt_Status = "Critical"
            if ($safeHosts.Contains($esx))
            {
                if ($verbose -or $succinct){Write-Host "Identified this as a safe host to fix automatically, Attempting fix."}
                $results.item($index).Reboot_Required = "Yes"
                $setChange = Get-AdvancedSetting -Entity $esx -Name VMFS3.UseATSForHBOnVMFS5 | Set-AdvancedSetting -Value 0 -Confirm:$false
                if ($verbose -or $succinct){
                    if ($setChange.Value -eq 0)
                    {
                        Write-Host "Fix successful." -ForegroundColor Green
                        $results.Item($index).Found_ATS_HB = $setChange.Value
                    }
                    else
                    {Write-Host "Fix Failed." -foregroundColor Red }
                    Write-Host -ForegroundColor Cyan "You will need to reboot this host."
                }
            }
        }
        elseif ($succinct -eq $true)
        {
            Write-Host -ForegroundColor Green "ATS for Heartbeat on VMFS 5 Disabled."
        }


########
########    Item 2: Queue Depth
########
##
##  Set Queue Depth for Software iSCSI initiator to 16
##  Default value is 128 or 256
##  Datera recommended value is 16
##  Alternate method of implementation:
##      esxcli system module parameters set -m iscsi_vmk -p iscsivmk_LunQDepth=16
##
##  Check the command result:
##      esxcli system module parameters list -m iscsi_vmk | grep iscsivmk_LunQDepth
########

        if ($verbose -eq $true){ Write-Output ("==== iSCSI Queue depth on " + $esx.Name + " ====")}
        $esxcli = get-esxcli -VMHost $esx -v2
        $setting = $esxcli.system.module.parameters.list.Invoke(@{module="iscsi_vmk"}) | Where-Object {$_.Name -eq 'iscsivmk_LunQDepth'}

        if ($verbose -eq $true){ $setting | Format-List | Format-Color @{"Value\s*:\s(?!16)" = 'Red'; "Value\s*:\s*$DateraIscsiQueueDepth " = 'Green'}}
        if ($succinct -eq $true)
        {
            if ($setting.value -eq $DateraIscsiQueueDepth )
            {    Write-Host -ForegroundColor Green "iSCSI queue depth is $($setting.value)"}
            else
            {    Write-Host -ForegroundColor Red "Deviation: iSCSI queue depth is $($setting.value)"}
        }
        $optimalQD = $true
        if ($setting.Value -eq "")
        {
            $results.Item($index).Found_Queue_Depth = "NotConfigured"
            $optimalQD = $false
        }
        else
        {
            $results.Item($index).Found_Queue_Depth = $Setting.Value
            if ($setting.Value -ne $DateraIscsiQueueDepth ){
                $optimalQD = $false}
        }
        if (-not $optimalQD -and $safeHosts.Contains($esx))
        {
            $DQDString = "iscsiVMK_LunQDepth=$DateraIscsiQueueDepth"
            if ($verbose -or $succinct){Write-Host "Identified this as a safe host to fix automatically, Attempting fix."}
            $qDepth = @{
                    module = 'iscsi_vmk'
                    parameterstring = 'iscsiVMK_LunQDepth='+$DateraIscsiQueueDepth
                    }
            try {
                $setChange = $esxcli.system.module.parameters.set.Invoke($qDepth)
                Write-Host "Fix successful." -ForegroundColor Green
                $results.Item($index).Found_Queue_Depth = $setChange.Value
            }
            catch
            {Write-Host "Fix Failed." -foregroundColor Red }

        }
        if ($results.Item($index).Found_Queue_Depth -ne $DateraIscsiQueueDepth  -and $results.Item($index).Opt_Status -eq "Optimal") {$results.Item($index).Opt_Status = "Suboptimal"}



########
########    Item 3: Delayed Ack
########
##
##  Turn Off DelayedAck for Random Workloads
##  Default application value is 1 (Enabled)
##  Modified application value is 0 (Disabled)
##
##  Alternate method of implementation:
##      export iscsi_if=`esxcli iscsi adapter list | grep iscsi_vmk | awk '{ print $1 }'`
##      vmkiscsi-tool $iscsi_if -W -a delayed_ack=0
##
##      export iscsi_if=`esxcli iscsi adapter list | grep iscsi_vmk | awk '{ print $1 }'`
##      vmkiscsi-tool -W $iscsi_if | grep delayed_ack
##      or
##      vmkiscsid --dump-db | grep Delayed
##  For details, please refer to https://kb.vmware.com/s/article/1002598
##
########

        if ($verbose -eq $true){Write-Output ("==== Delayed ACK of software iSCSI adapter on " + $esx.Name + " ====")}
        $adapterId = $esx.ExtensionData.config.StorageDevice.HostBusAdapter | Where{$_.Driver -match "iscsi_vmk"}
        if ($adapterId.Count -gt 1)
        {
            Write-Host -ForegroundColor DarkRed -BackgroundColor Yellow "Warning: Multiple iSCSI Adapters Found, results may be inaccurate"
            if ($results.Item($index).Opt_Status -eq "Optimal")
                {$results.Item($index).Opt_Status = "Unclear"}
        }
        foreach($adapter in $adapterId){
            $adapter_name = $adapter.IScsiName
            $setting =  $esxcli.iscsi.adapter.param.get.Invoke(@{adapter=$adapter.Device}) | Where{$_.Name -eq "DelayedACK"}

            if ($verbose)
            {
                $setting | Format-List | Format-Color @{"Current\s*:\s*true" = 'Red'; "Current\s*:\s*false" = 'Green'}
            }
            elseif ($succinct){
                if ($setting.Current -eq "false"){Write-Host "Delayed Ack is off." -ForegroundColor Green}
                else{Write-Host "Deviation: Delayed Ack is on." -ForegroundColor Red}
            }
            $results.Item($index).Found_Delayed_Ack = $setting.Current
            if ($setting.Current -eq "true")
            {
                if($safehosts.Contains($esx)){
                    if ($verbose -or $succinct){Write-Host "Identified this as a safe host to fix automatically, Attempting fix."}
                    try {
                        $options = New-Object VMWare.Vim.HostInternetScsiHbaParamValue[] (1)
                        $options[0] = New-Object VMware.Vim.HostInternetScsiHbaParamValue
                        $options[0].key = "DelayedAck"
                        $options[0].value = $true

                        $HostiSCSISoftwareAdapterHBAID = $adapter.device
                        $HostStorageSystem = Get-View -ID $HostStorageSystemID
                        $HostStorageSystem.UpdateInternetScsiAdvancedOptions($HostiSCSISoftwareAdapterHBAID, $null, $options)


                        Write-Host "Fix successful." -ForegroundColor Green
                        $results.Item($index).Found_Delayed_Ack = "false"
                    }
                    catch
                    {Write-Host "Fix Failed." -foregroundColor Red }
                }
            }
            if ($results.Item($index).Found_Delayed_Ack -eq "true" -and $results.Item($index).Opt_Status -eq "Optimal")
                {$results.Item($index).Opt_Status = "Suboptimal"}
        }

        if ($adapterId.Count -eq 0)
        {
            if ($verbose -eq $true -or $succinct -eq $true){
                Write-Host -ForegroundColor Red "Deviation: No iSCSI Adapter Found."
            }
            $results.Item($index).Found_Delayed_Ack = "NoAdapter"
        }



########
########    Item 4: NMP SATP Rule
########
##
##  Create Custom SATP Rule for DATERA
##
##  Alternate method of implementation:
##  esxcli storage nmp satp rule add -s VMW_SATP_ALUA -P VMW_PSP_RR -O iops=1 -V DATERA -e "DATERA custom SATP rule"
##  add(boolean boot,
##      string claimoption,
##      string description,
##      string device,
##      string driver,
##      boolean force,
##      string model,
##      string option,
##      string psp,
##      string pspoption,
##      string satp,
##      string transport,
##      string type,
##      string vendor)
##      -s = The SATP for which a new rule will be added
##      -P = Set the default PSP for the SATP claim rule
##      -O = Set the PSP options for the SATP claim rule (option=string
##      -V = Set the vendor string when adding SATP claim rules. Vendor rules are mutually exclusive with driver rules (vendor=string)
##      -e = Claim rule description
##
##  !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
##  !!! Configuration changes take effect after rebooting ESXI hosts            !!!
##  !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
##
##  To remove the claim rule:
##  esxcli storage nmp satp rule remove -s VMW_SATP_ALUA -P VMW_PSP_RR -O iops=1 -V DATERA -e "DATERA custom SATP rule"
##  To verify the claim rule:
##  esxcli storage nmp satp rule list
##
## Result Looks like
##  ClaimOptions :
##  DefaultPSP   : VMW_PSP_RR
##  Description  : DATERA custom SATP rule
##  Device       :
##  Driver       :
##  Model        :
##  Name         : VMW_SATP_ALUA
##  Options      :
##  PSPOptions   : iops='1'
##  RuleGroup    : user
##  Transport    :
##  Vendor       : DATERA
##
########

        if ($verbose -eq $true) {Write-Output ("==== NMP SATP RULE of DATERA on " + $esx.Name + " ====")}
        $NmpSatpRule = $esxcli.storage.nmp.satp.rule.list.Invoke() | Where{$_.Vendor -eq "DATERA"}
        if ($NmpSatpRule -eq $null) {
            if ($verbose -or $succinct){ Write-Host -ForegroundColor Red "Deviation: No customized NMP SATP RULE for DATERA on $($esx.Name)"}
            $results.Item($index).Found_NMP_SATP_Rule = 'NotPresent'
            if ($safeHosts.Contains($esx))
            {
                if ($verbose -or $succinct){Write-Host "Identified this as a safe host to fix automatically, Attempting fix."}
                $SatpArgs = $esxcli.storage.nmp.satp.rule.remove.createArgs()
                $SatpArgs.description = "DATERA custom SATP Rule"
                $SatpArgs.vendor = "DATERA"
                $SatpArgs.satp = "VMW_SATP_ALUA"
                $SatpArgs.psp = "VMW_PSP_RR"
                $SatpArgs.pspoption = "iops=1"
                $result=$esxcli.storage.nmp.satp.rule.add.invoke($SatpArgs)

                if ($result){
                        if ($verbose -or $succinct){Write-Host "DATERA custom SATP rule [RR, iops=1] is created for $($esx.name)" -ForegroundColor Green}
                        $results.Item($index).Found_NMP_SATP_Rule = 'Present'

                if ($verbose){
                         Write-Host "
                     !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
                     !!                                                                !!
                     !!  Configuration changes take effect after rebooting ESXI hosts  !!
                     !!  Please move ESXi host to maintenance mode, then reboot them   !!
                     !!                                                                !!
                     !!  Please DON'T reboot ESXi if there are datastores/storage      !!
                     !!  connected to ESXi host                                        !!
                     !!                                                                !!
                     !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
                             " -ForegroundColor Magenta
                     }
                if ($succinct){Write-Host "!!!!!! Configuration changes take effect after rebooting ESXI hosts !!!!!!" -ForegroundColor Cyan}
                }
                else
                {
                   $results.Item($index).Found_NMP_SATP_Rule = 'NotPresent'
                    if ($results.Item($index).Opt_Status -eq "Optimal"){$results.Item($index).Opt_Status = "Suboptimal"}
                }
            }
            else
            {
               $results.Item($index).Found_NMP_SATP_Rule = 'NotPresent'
               if ($results.Item($index).Opt_Status -eq "Optimal"){$results.Item($index).Opt_Status = "Suboptimal"}
            }
        }
        else
        {
            if ($verbose) {Write-Output ($NmpSatpRule) | Format-Color @{'' = 'Green'}}
            if ($succinct) {Write-Host -ForegroundColor Green "Found expected NMP SATP Rule."}
            $results.Item($index).Found_NMP_SATP_Rule = 'Present'
        }



########
########    Cleanup
########

    if ($verbose -or $succinct)
    {
        if($results.Item($index).Opt_Status -ne "Optimal")
        {
            if($results.Item($index).Connection_State -eq "Maintenance")
            {
                Write-Host "Host is in Maintenance Mode, Run script with update parmeter to fix." -ForegroundColor Green
            }
            elseif ($results.Item($index).Found_ATS_HB -eq 0)
            {
                Write-Host "Please consider fixing this host for performance improvements." -ForegroundColor Yellow
            }
            else
            {
                Write-Host "This host is a danger to your environment.  Fix immediately!" -ForegroundColor Red
            }
        }
        Write-Host ""
    }
}

}

########
########     Output
########

if ($verbose -or $succinct){
Write-PSObject $results -MatchMethod Exact, Exact, Exact, Query, Query, Query, `
                                     Exact, Exact, Query, Query, Exact, Exact, Query, Exact `
                        -Column "Opt_Status", "Connection_State", "Found_ATS_HB", "Found_Queue_Depth", "Found_Delayed_Ack", "Found_NMP_SATP_Rule", `
                                    "Found_ATS_HB", "Found_Queue_Depth", "Found_Delayed_Ack", "Name", "Opt_Status" , "Opt_Status", "Name", "Reboot_Required" `
                        -Value "Critical", "Maintenance", "1", "'Found_Queue_Depth' -ne '16'", "'Found_Delayed_Ack' -ne 'false'", "'Found_NMP_SATP_Rule' -ne 'Present'", `
                                    "0", 16, "'Found_Delayed_Ack' -eq 'false'", "'Opt_Status' -eq 'Critical' -and 'Connection_State' -ne 'Maintenance'", `
                                    "Suboptimal", "Optimal", "'Opt_Status' -eq 'Suboptimal' -and 'Connection_State' -ne 'Maintenance'", "Yes"  `
                        -ValueForeColor Red, Green, Red, Red, Red, Red, `
                                    Green, Green, Green, Red, Yellow, Green, Yellow, Cyan, White

}

$critical = 0;
$suboptimal = 0;
$maintmode = 0;
$rebootNeeded = 0;

foreach ($esxiHost in $results)
{
    if ($esxiHost.Opt_Status -eq "Critical"){
        $critical++
        if ($esxiHost.Connection_State -eq "Maintenance")
        {
            $maintmode ++
        }
    }
    if ($esxiHost.Opt_Status -eq "Suboptimal"){
        $suboptimal++
    }
    if ($esxiHost.Reboot_Required -eq "Yes"){
        $rebootNeeded ++
    }
}
if ($critical -gt 0 -or $suboptimal -gt 0 -or $rebootNeeded -gt 0)
{
    Write-Host "
    Found $critical Critical, $maintmode MM Critical, and $suboptimal Suboptimal hosts in $vcenterServer"
    Write-Host "$rebootNeeded Hosts need to be rebooted."
    $Header = @"
<style>
TABLE {  font-family: Tahoma, Geneva, sans-serif;
    border: 1.5px solid #bbFFFF;
    text-align: center;
    font-size: 11px;
    border-collapse: collapse;}
TD {border-width: 2px; padding: 3px 15px; border-style: solid; border-color: blue;}
H2 {font-family: Tahoma, Geneva, sans-serif;}
H3 {font-family: Tahoma, Geneva, sans-serif;}
</style>
"@

    $body =  $results | ConvertTo-Html -Body "<h2>Found $critical Critical, $maintmode MM Critical, and $suboptimal Suboptimal hosts in $vcenterServer </h2>" -Head $header -PostContent "<h3>Better living through automation.(tm)</h3>Report run at $((get-date).ToUniversalTime().ToString("yyyy-MM-dd HH:mm:ss UTC"))" | Out-String

    if ($SendEmail)
    {
        if ($critical -gt 0 )
        {$subject = "[CRITICAL] Datera Config Checker: $vcenterServer"
        }
        else
        {$subject = "[info] Datera Config Checker: $vcenterServer"}
        Email-Alert -To "$SMTP_TO" -Subject $subject -Message $body -SMTP_RELAY $SMTP_RELAY -SMTP_FROM $SMTP_FROM
    }
}
else{
Write-Host "Great Job, everything looks good."}



