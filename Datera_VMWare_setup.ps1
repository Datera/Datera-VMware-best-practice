<#
         Datera VMware Best Practices Implementation Script
 
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
########  User Input Section
########

Param([parameter(Mandatory=$false,
   HelpMessage="
     !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
     !!  The script is used to disable ATS heartbeat and   !!
     !!  to change 3 iSCSI parameters globally on new      !!
     !!  ESXi hosts without datastore/storage.             !!
     !!    - Disable ATS Heartbeat                         !!
     !!    - Disable DelayedAck on software iSCSI adapter  !!
     !!    - Set iSCSI queue depth to 16                   !!
     !!    - Set Datera NMP SATP Rule to                   !!
     !!      VMW_PSP_RR and IOPS = 1                       !!
     !!                                                    !!
     !!  This may cause mis-function on ESXi hosts         !!
     !!  If you have sorage connected, it is your risk     !!
     !!  to update configuration of software iSCSI adapter !!
     !!  via this script.                                  !!
     !!                                                    !! 
     !!  This script is offered `"as is`" with no warranty.  !!
     !!  I will not be liable for any damage or loss to    !!
     !!  the system if you run this script. You need to    !!
     !!  test on your platform and understand the script.  !!
     !!                                                    !!
     !!  If you agree to proceed, please enter `"Yes`" to    !!
     !!  update; otherwise enter `"No`" to only display      !!
     !!  the current setup.                                !!
     !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
   ")]
   [string]$Update)

function Format-Color([hashtable] $Colors = @{}, [switch] $SimpleMatch) {
        $lines = ($input | Out-String) -replace "`r", "" -split "`n"
        foreach($line in $lines) {
                $color = ''
                foreach($pattern in $Colors.Keys) {
                        if(!$SimpleMatch -and $line -match $pattern) { $color = $Colors[$pattern] }
                        elseif ($SimpleMatch -and $line -like $pattern) { $color = $Colors[$pattern] }
                }
                if($color) {
                        Write-Host -ForegroundColor $color $line
                } else {
                        Write-Host $line
                }
        }
}

$updateESXi = $false
if ($Update -ne $null) {
    if ($Update -eq "yes") {
        $updateESXi = $true
    }
} 

## That means script output tells user what is happening throughout 
## the script.
$verbose = $true

## That means no confirmation received for the command to change 
## the advanced settings  
$Confirm = $false

## Before you run this script, you have to make sure all ESXi hosts 
## must be actively managed by Windows vCenter server.  
$vmhosts = Get-VMhost
<#
PowerCLI C:\Users\Administrator\ghg> $vmhosts = Get-VMhost
PowerCLI C:\Users\Administrator\ghg> echo $vmhosts

Name                 ConnectionState PowerState NumCpu CpuUsageMhz CpuTotalMhz   MemoryUsageGB   MemoryTotalGB Version
----                 --------------- ---------- ------ ----------- -----------   -------------   ------------- -------
tlx192.tlx.datera... Connected       PoweredOn      16        1089       38384          27.479         127.895   6.0.0
tlx191.tlx.datera... Connected       PoweredOn      16         193       38384           3.350         127.895   6.0.0
#>

$results = $vmhosts | Select-Object Name

$results | add-member -Membertype NoteProperty -Name Found_ATS_HB -Value NotSet
$results | add-member -Membertype NoteProperty -Name Expected_ATS_HB -Value 0
$results | add-member -Membertype NoteProperty -Name Found_Queue_Depth -Value NotSet
$results | add-member -Membertype NoteProperty -Name Expected_Queue_Depth -Value 16
$results | add-member -Membertype NoteProperty -Name Found_Delayed_Ack -Value NoAdaptorPresent
$results | add-member -Membertype NoteProperty -Name Expected_Delayed_Ack -Value false
$results | add-member -Membertype NoteProperty -Name Found_NMP_SATP_Rule -Value NotSet
$results | add-member -Membertype NoteProperty -Name Expected_NMP_SATP_Rule -Value Present

########    
########    Script
########

if($verbose -eq $true){
Write-Output "
          _________
         /     ___ \
        /     |___\ \
       |      |____| |
       |      |____| |
        \     |___/ /
         \_________/

   Datera VMware Best Practices 
       Configuration Script

"
}

Write-Output ("====== List current ESXi hosts managed by vCenter ======")
echo $vmhosts
Write-Output (" ")



if ($updateESXi -eq $true) {

########
########    Option 1: ATS heartbeat
########

    Write-Output ("Disable ATS heartbeat on all ESXi hosts, otherwise iSCSI will misfunction")

    foreach($esx in $vmhosts){

        Get-AdvancedSetting -Entity $esx -Name VMFS3.UseATSForHBOnVMFS5 | Set-AdvancedSetting -Value 0 -Confirm:$false
   
        if($verbose -eq $true){
            Write-Output ("ATS heartbeat is disabled for " + $esx.name + " successfully")
        }
    }

    <# 
    1 | Disable ATS Heartbeat on each ESXi host
    Alternate method of implementation:
        esxcli system settings advanced set -i 0 -o /VMFS3/UseATSForHBOnVMFS5

    For details, please refer to https://kb.vmware.com/s/article/2113956
    #>

    ########
    ########  The following parameters change needs no iSCSI target at all on ESXi 
    ########

    if ($verbose -eq $true){
         Write-Output "
    !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
    !!                                                       !!
    !! This script doesn't run on the ESXi host that has     !!
    !! iSCSI target in case you run this script by mistake   !!
    !!                                                       !!
    !! You have two choices:                                 !!
    !! 1.  Remove iSCSI targets from dynamic discovery and   !!
    !!     static target, removing the iSCSI targets will    !!
    !!     cause your ESXi datastore misfunction. You need   !!
    !!     to know what you're doing and risks               !!
    !!     Re-run this script again after removing them      !!
    !!                                                       !! 
    !! 2.  If you really want to run this script no matter   !!
    !!     what, you know what you're doing and it may cause !!
    !!     system misfunction.                               !!
    !!     You may replace the following 8 lines with the    !!
    !!     following line                                    !!
    !!                                                       !!
    !!     `$hostsToBeExecuted = `$vmhosts                     !!  
    !!                                                       !!
    !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

    "
    }

    $hostsToBeExecuted = @()
    foreach ($esx in $vmhosts) {
    $IscsiHba = $esx | Get-VMHostHba -Type iScsi | Where {$_.Model -eq "iSCSI Software Adapter"}
    $IscsiTarget = Get-IScsiHbaTarget -IScsiHba $IscsiHba
    if ($IscsiTarget -eq $null) {
        $hostsToBeExecuted +=  $esx
        }
    }

    Write-Output ("====== List ESXi hosts without iSCSI target that we can run this script ======")
    echo $hostsToBeExecuted
    Write-Output (" ")

    if ($verbose -eq $true){
        Write-Output "

########
######## Set up iSCSI parameters on the above ESXi hosts
########
 
    "
    }

    ########
    ########    Option 2: Queue Depth    
    ########

    <#
    2 | Set Queue Depth for Software iSCSI initiator to 16
    Default value is 128 or 256
    Datera recommended value is 16
    Alternate method of implementation:
        esxcli system module parameters set -m iscsi_vmk -p iscsivmk_LunQDepth=16

    Check the command result:
        esxcli system module parameters list -m iscsi_vmk | grep iscsivmk_LunQDepth
    #>

    $DateraIscsiQueueDepth = 16
    foreach ($esx in $hostsToBeExecuted){
        $esxcli = get-esxcli -VMHost $esx

        If ($esx.Version.Split(".")[0] -ge "6"){
            #vSphere 6.x or greater
            $esxcli.system.module.parameters.set($null, $null,"iscsi_vmk","iscsivmk_LunQDepth=$DateraIscsiQueueDepth")
        }else{
            #vSphere 5.x command
            $esxcli.system.module.parameters.set($null,"iscsi_vmk","iscsivmk_LunQDepth=$DateraIscsiQueueDepth")
        }

        $esxcli.system.module.parameters.list("iscsi_vmk") | Where{$_.Name -eq "iscsivmk_LunQDepth"}
        if ($verbose -eq $true){
            Write-Output ("Queue depth for " + $esx.Name + " is set to $DateraIscsiQueueDepth")
            Write-Output ("  ")
        }
    }

    ########
    ########    Option 3: DelayedAck
    ########

    <# 
    3 | Turn Off DelayedAck for Random Workloads
    Default application value is 1 (Enabled)
    Modified application value is 0 (Disabled)

    Alternate method of implementation:
        export iscsi_if=`esxcli iscsi adapter list | grep iscsi_vmk | awk '{ print $1 }'`
        vmkiscsi-tool $iscsi_if -W -a delayed_ack=0

        export iscsi_if=`esxcli iscsi adapter list | grep iscsi_vmk | awk '{ print $1 }'`
        vmkiscsi-tool -W $iscsi_if | grep delayed_ack                 
        or
        vmkiscsid --dump-db | grep Delayed
    For details, please refer to https://kb.vmware.com/s/article/1002598
    #>

    foreach($esx in $hostsToBeExecuted){
        $view = Get-VMHost $esx | Get-View  
        $StorageSystemId = $view.configmanager.StorageSystem  
        $IscsiSWAdapterHbaId = ($view.config.storagedevice.HostBusAdapter | where {$_.Model -match "iSCSI Software"}).device  
       
        $options = New-Object VMWare.Vim.HostInternetScsiHbaParamValue[](1)  
        $options[0] = New-Object VMware.Vim.HostInternetScsiHbaParamValue  
        $options[0].key = "DelayedAck"  
        $options[0].value = $false  
       
        $StorageSystem = Get-View -ID $StorageSystemId  
        $StorageSystem.UpdateInternetScsiAdvancedOptions($IscsiSWAdapterHbaId, $null, $options) 

        if ($verbose -eq $true){
            Write-Output ("Disable DelayedAck of Software iSCSI adapter on " + $esx.name)
            Write-Output ("  ")
        }
    }  

    ########
    ########    Option 4: SATP Rule
    ########

    <# 
    4 | Create Custom SATP Rule for DATERA

    Alternate method of implementation:
    esxcli storage nmp satp rule add -s VMW_SATP_ALUA -P VMW_PSP_RR -O iops=1 -V DATERA -e "DATERA custom SATP rule"
    add(boolean boot, 
        string claimoption, 
        string description, 
        string device, 
        string driver, 
        boolean force, 
        string model, 
        string option, 
        string psp, 
        string pspoption, 
        string satp, 
        string transport, 
        string type, 
        string vendor)
        -s = The SATP for which a new rule will be added
        -P = Set the default PSP for the SATP claim rule
        -O = Set the PSP options for the SATP claim rule (option=string
        -V = Set the vendor string when adding SATP claim rules. Vendor rules are mutually exclusive with driver rules (vendor=string)
        -e = Claim rule description

    !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
    !!! Configuration changes take effect after rebooting ESXI hosts            !!!
    !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

    To remove the claim rule:
    esxcli storage nmp satp rule remove -s VMW_SATP_ALUA -P VMW_PSP_RR -O iops=1 -V DATERA -e "DATERA custom SATP rule"
    To verify the claim rule:
    esxcli storage nmp satp rule list
    #>

    foreach($esx in $hostsToBeExecuted){
        $esxcliv2=Get-Esxcli -VMHost $esx -v2
        $SatpRule = $esxcliv2.storage.nmp.satp.rule.list.invoke() | Where{$_.Vendor -eq "DATERA"}
   
        if ($SatpRule -eq $null) {
            $SatpArgs = $esxcliv2.storage.nmp.satp.rule.remove.createArgs()
            $SatpArgs.description = "DATERA custom SATP Rule"
            $SatpArgs.vendor = "DATERA"
            $SatpArgs.satp = "VMW_SATP_ALUA"
            $SatpArgs.psp = "VMW_PSP_RR"
            $SatpArgs.pspoption = "iops=1"
            $result=$esxcliv2.storage.nmp.satp.rule.add.invoke($SatpArgs)

            if ($result){
                Write-Output ("DATERA custom SATP rule [RR, iops=1] is created for " + $esx.name)
                Write-Output (" ")
            }
        }   
        else {
            Write-Output ("DATERA custom SATP rule on " + $esx.name)
            Write-Output ($SatpRule) 
        }
    }

    if ($verbose -eq $true){
        Write-Output "

    !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
    !!                                                                !!
    !!  This script is only used for setup iSCSI parameters on new    !!
    !!  ESXi without datastore and without iSCSI target               !! 
    !!                                                                !!
    !!  Configuration changes take effect after rebooting ESXI hosts  !!
    !!  Please move ESXi host to maintenance mode, then reboot them   !!
    !!                                                                !!
    !!  Please DON'T reboot ESXi if there are datastores/storage      !!
    !!  connected to ESXi host                                        !!
    !!                                                                !!
    !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

         "
    }
    Write-Output ("!!!!!! Configuration changes take effect after rebooting ESXI hosts !!!!!!")
    echo $hostsToBeExecuted
    Write-Output (" ")
}

########
######## List 3 iSCSI parameters 
########

if ($verbose -eq $true){
Write-Output "

########
######## Display iSCSI parameters on all ESXi hosts
########
 
"
}

foreach ($esx in $vmhosts){
    Write-Output ("########## " + $esx.Name + " ##########") 
    Write-Output ("  ")
    $index = $vmhosts.IndexOf($esx)

    # ATS heartbeat status
    Write-Output ("==== ATS heartbeat on " + $esx.Name + " (1:enabled 0:disabled) " + " ====")
    $setting = Get-AdvancedSetting -Entity $esx -Name VMFS3.UseATSForHBOnVMFS5
    $setting | Format-List | Format-Color @{"Value\s*:\s*1$" = 'Red'; "Value\s*:\s*0" = 'Green'}
    $value = $setting | Select-Object Value

    $results.Item($index).Found_ATS_HB = $value.Value

    # iSCSI queue depth
    Write-Output ("==== iSCSI Queue depth on " + $esx.Name + " ====")
    $esxcli = get-esxcli -VMHost $esx
    $setting = $esxcli.system.module.parameters.list("iscsi_vmk") | Where{$_.Name -eq "iscsivmk_LunQDepth"}
    $setting | Format-List | Format-Color @{"Value\s*:\s(?!16)" = 'Red'; "Value\s*:\s*16" = 'Green'}
    $value = $setting | Select-Object Value

    $results.Item($index).Found_Queue_Depth = $value.Value

    # Delayed Ack
    Write-Output ("==== Delayed ACK of software iSCSI adapter on " + $esx.Name + " ====")
    $adapterId = $esx.ExtensionData.config.StorageDevice.HostBusAdapter | Where{$_.Model -match "iSCSI"}
    foreach($adapter in $adapterId){
        $adapter_name = $adapter.IScsiName
        $setting = $esxcli.iscsi.adapter.param.get($adapter.device) | Where{$_.Name -eq "DelayedACK"} | Select ID, Current
        $setting | Format-List | Format-Color @{"Current\s*:\s*true" = 'Red'; "Current\s*:\s*false" = 'Green'}

        $results.Item($index).Found_Delayed_Ack = $setting.Current
    }
    
    # nmp satp rule
    Write-Output ("==== NMP SATP RULE of DATERA on " + $esx.Name + " ====")
    $NmpSatpRule = $esxcli.storage.nmp.satp.rule.list() | Where{$_.Vendor -eq "DATERA"}

    if ($NmpSatpRule -eq $null) {
        Write-Output (" No customized NMP SATP RULE for DATERA on " + $esx.Name) | Format-Color @{'' = 'Red'}
        Write-Output ("  ")
        $results.Item($index).Found_NMP_SATP_Rule = 'Not Present'
    } else {
        Write-Output ($NmpSatpRule) | Format-Color @{'' = 'Green'}
        $results.Item($index).Found_NMP_SATP_Rule = 'Present'
    }
    Write-Output ("  ") 
}

$results | Format-Table

<# Result Looks like:
ClaimOptions :
DefaultPSP   : VMW_PSP_RR
Description  : DATERA custom SATP rule
Device       :
Driver       :
Model        : 
Name         : VMW_SATP_ALUA
Options      :
PSPOptions   : iops='1'
RuleGroup    : user
Transport    :
Vendor       : DATERA
#>
