<#
    .SYNOPSIS
    Runs a PowerShell scriptblock or script on an Azure VM using the Custom Script Extension.
        
    .SYNTAX
    Push-AzureVMCommand `
    -AzureOrgIdCredential <System.Management.Automation.PSCredential> `
    -AzureSubscriptionName <System.String> `
    [-Container <System.String>] `
    [-PollingIntervalInSeconds <System.Int>] `
    [-ScriptArguments <System.String>] `
    [-ScriptBlock <System.String>] `
    [-ScriptName <System.String>] `
    -ServiceName <System.String> `
    -StorageAccountName <System.String> `
    [-TimeoutLimitInSeconds <System.Int>] `
    -VMName <System.String> `
    -WaitForCompletion <System.Boolean>
        
    .DESCRIPTION
    This Runbook takes a PowerShell scriptblock supplied at runtime or an existing script and runs it on a defined Azure VM, optionally returning the output of the script or scriptblock.
        
    .PARAMETER ServiceName
    Specifies the name of the Cloud Service that contains the Azure VM to target.
        
    .PARAMETER VMName
    Specifies the name of the Azure VM which the script will run on.
        
    .PARAMETER ScriptBlock
    Specifies the PowerShell scriptblock (as a string) that will be run on the Azure VM specified.
        
    .PARAMETER ScriptName
    Specifies the PowerShell script file that will be run on the Azure VM specified. Assumes the script file is already in an Azure Storage container.
        
    .PARAMETER ScriptArguments
    Specifies any arguments required for the PowerShell scriptblock or script file.
        
    .PARAMETER Container
    Specifies the Azure Storage Blob container that contains the script file specified, or where the scriptblock will be written. Defaults to "customscripts".

    .PARAMETER AzureOrgIdCredential
    Specifies the Azure Active Directory OrgID user credential object used to authenticate to Azure.
        
    .PARAMETER AzureSubscriptionName
    Specifies the name of the Azure Subscription containing the resources targetted by this runbook.
        
    .PARAMETER StorageAccountName
    Specifies the name of the Azure Storage account used to store the script files used in this runbook.

    .PARAMETER PollingIntervalInSeconds
    Specifies the time in seconds between checks for script completion on the virtual machine. Defaults to 15 seconds.

    .PARAMETER TimeoutLimitInSeconds
    Specifies the time in seconds before the runbook times out checking for script completion on the virtual machine. Default to 900 seconds (15 minutes). 
        
    .PARAMETER WaitForCompletion
    A Boolean value, when set to $true will wait for script to complete and return the standard or error output of the script run on the Azure VM. Defaults to $false.
            
    .INPUTS
    None. You cannot pipe objects to Push-Command.
        
    .OUTPUTS
    System.String Push-AzureVMCommand returns a string with either a success message, or the output of the script run on the Azure VM (if WaitForCompletion is set to $true).
        
    .EXAMPLE
    $result = Push-AzureVMCommand `
        -AzureOrgIdCredential $OrgIDCred `
        -AzureSubscriptionName $AzureSubscriptionName `
        -Container "azurevmscripts" `
        -PollingIntervalInSeconds 60
        -ScriptArguments "-Path c:\temp" `
        -ScriptName "MoveLogFiles.ps1" `
        -ServiceName "WebApplicationCloudService" `
        -StorageAccountName "ProductionStorage" `
        -TimeoutLimitInSeconds 600 `
        -VMName "VM01" `
        -WaitForCompletion $true
                
    .EXAMPLE
    $result = Push-AzureVMCommand `
        -AzureOrgIdCredential $OrgIDCred `
        -AzureSubscriptionName $AzureSubscriptionName `
        -Container "azurevmscripts" `
        -ScriptBlock "
            `$service = get-service
            Write-Output `$service
        " `
        -ServiceName "WebApplicationCloudService" `
        -StorageAccountName "ProductionStorage" `
        -VMName "VM01" `
        -WaitForCompletion $true

    .EXAMPLE
    $result = Push-AzureVMCommand `
        -AzureOrgIdCredential $OrgIDCred `
        -AzureSubscriptionName $AzureSubscriptionName `
        -Container "azurevmscripts" `
        -ScriptBlock "
           param(`$CultureName)

           `$Culture = Get-Culture | Where { `$_.Name -eq `$CultureName }
           `$SerializedOutput = [System.Management.Automation.PSSerializer]::Serialize(`$Culture)
           
            Write-Output `$SerializedOutput 
        " `
        -ScriptArguments "-CultureName en-US" `
        -ServiceName "WebApplicationCloudService" `
        -StorageAccountName "ProductionStorage" `
        -VMName "VM01" `
        -WaitForCompletion $true
    
    $result = $result -ireplace "\\n", ""
    $OutputObject = [System.Management.Automation.PSSerializer]::Deserialize($result)
    Write-Output $OutputObject 
            
    .NOTES
    Author: Rob Costello, Microsoft Consulting Services
    Last Edit: 16/12/2014
#>
workflow Push-AzureVMCommand
{
    [OutputType([String])]
    param
    (
        [parameter(Mandatory=$true)]
        [string]$ServiceName,

        [parameter(Mandatory=$true)]
        [string]$VMName,

        [parameter(Mandatory=$false)]
        [string]$ScriptBlock,

        [parameter(Mandatory=$false)]
        [string]$ScriptName,

        [parameter(Mandatory=$false)]
        [string]$ScriptArguments,

        [parameter(Mandatory=$false)]
        [string]$Container="customscripts",

        [parameter(Mandatory=$true)]
        [PSCredential]$AzureOrgIdCredential,

        [parameter(Mandatory=$true)]
        [string]$AzureSubscriptionName,

        [parameter(Mandatory=$true)]
        [string]$StorageAccountName,

        [parameter(Mandatory=$false)]
        [int]$PollingIntervalInSeconds=15,

        [parameter(Mandatory=$false)]
        [int]$TimeoutLimitInSeconds=900,

        [parameter(Mandatory=$true)]
        [bool]$WaitForCompletion=$false
    )
    
    # Validate script details have been provided and exit if not found.
    if(!$ScriptBlock -and !$ScriptName)
    {
        throw("No script data specified. You must use either the ScriptBlock or the ScriptName parameter.")
    }
    
    # Validate only one method of script input has been provided
    if($ScriptBlock -and $ScriptName)
    {
        throw("ScriptBlock and ScriptName have been specified. You must use only one of these parameters.")
    }

    # By default, errors in PowerShell do not cause workflows to suspend, like exceptions do.
    # This means a runbook can still reach 'completed' state, even if it encounters errors
    # during execution. The below command will cause all errors in the runbook to be thrown as
    # exceptions, therefore causing the runbook to suspend when an error is hit.
    $ErrorActionPreference = "Stop"

    # Authenticate to Azure
    Write-Verbose "Authenticating to Azure..."
    Add-AzureAccount -Credential $AzureOrgIdCredential | Write-Verbose
    Select-AzureSubscription -SubscriptionName $AzureSubscriptionName | Write-Verbose
    Set-AzureSubscription -SubscriptionName $AzureSubscriptionName -CurrentStorageAccountName $StorageAccountName | Write-Verbose
            
    # Validate script exists in blob storage if $ScriptName specified
    if($ScriptName)
    {
        if(!(Get-AzureStorageContainer -Name $Container -ErrorAction SilentlyContinue))
        {
            Write-Verbose "Existing container not found: $Container. Cannot continue."
            throw("Existing container $Container for script file could not be found, exiting.")
        }
        
        $script = $ScriptName
        try
        {
            Write-Verbose "Checking for script in blob container..."
            Get-AzureStorageBlob -Blob $script -Container $Container | Write-Verbose
        }
        catch
        {
            Write-Verbose "Blob not found!"
            throw("No script file found in blob storage. Please verify script is available in the container specified.")
        }            
    }
            
    # Upload script to blob storage if $ScriptBlock specified
    if($ScriptBlock)
    {
        Write-Verbose "Using ScriptBlock, creating local file to write file for uploading to Blob Storage..."

        # Create temporary name and path for the script block
        $scriptGUID = InlineScript{([GUID]::NewGuid()).ToString()}
        $script = $scriptGUID + ".ps1"
        $localPath = "C:\CustomScripts"
                
        # Write script block to local file
        try
        {
            if(!(Get-Item -Path $localPath -ErrorAction SilentlyContinue))
            {
                Write-Verbose "Creating local directory: $localPath"
                New-Item -Path $localPath -ItemType Directory | Write-Verbose
            }

            Write-Verbose "Adding scriptblock content to new file..."
            Add-Content -Path "$localPath\$script" $ScriptBlock | Write-Verbose
        }
        catch
        {
            Write-Verbose "Could not write script block to a file!"
            throw("No script file could be written to local file on runbook worker.")
        } 
                
        # Validate blob storage container exists, and create if not found
        Write-Verbose "Validating container $Container exists in Azure Storage."
        if(!(Get-AzureStorageContainer -Name $Container -ErrorAction SilentlyContinue))
        {
            Write-Verbose "Creating new container: $Container"
            New-AzureStorageContainer -Name $Container | Write-Verbose
        }
                
        # Upload script to blob storage container
        try
        {
            Write-Verbose "Uploading file to blob storage: $script"
            Set-AzureStorageBlobContent -Container $Container -File "$localPath\$script" -Blob $script -Force | Write-Verbose
        }
        catch
        {
            Write-Verbose "Could not upload script to blob storage!"
            throw("Script file could not be uploaded to blob storage.")
        }
    }
    
    $csePreviousTimeStamp = InlineScript {

        # Get the VM to run script against
        $vm = Get-AzureVM -ServiceName $Using:ServiceName -Name $Using:VMName
        
        # Get the current CSE status timestamp before calling Update-AzureVM, used to evaluate completion of CSE job.
        try
        {
            $csePreviousStatus = $vm.ResourceExtensionStatusList | Where{$_.HandlerName -eq "Microsoft.Compute.CustomScriptExtension"}
            $csePreviousTimeStamp = $csePreviousStatus.ExtensionSettingStatus.TimestampUtc.ToString()
        }
        catch
        {
            Write-Verbose "Error getting previous Custom Script extension data, indicates CSE not currently enabled on this VM."
            $csePreviousTimeStamp = "empty"
        }
        
        Write-Verbose "Old TimeStamp: $csePreviousTimeStamp"
        
        # Set the custom script extension to retrieve script from blob storage and update the VM
        if($Using:ScriptArguments)
        {
            Write-Verbose "Running script with arguments: $Using:ScriptArguments"
            Set-AzureVMCustomScriptExtension -VM $vm -ContainerName $Using:Container -FileName $Using:script -Run $Using:script -Argument $Using:ScriptArguments | Update-AzureVM | Write-Verbose
        }
        else
        {
            Write-Verbose "Running script with no arguments."
            Set-AzureVMCustomScriptExtension -VM $vm -ContainerName $Using:Container -FileName $Using:script -Run $Using:script | Update-AzureVM | Write-Verbose
        }  
        
        Write-Output $csePreviousTimeStamp 
    }

    # Retrieve status if required and output
    if($WaitForCompletion)
    {
        $maxAttempts = InlineScript {
            [MidpointRounding]$mode = 'AwayFromZero'
            $maxAttempts = [Math]::Round(($Using:TimeoutLimitInSeconds/$Using:PollingIntervalInSeconds),$mode)
            
            Write-Output $maxAttempts
        }
        $currentAttempt = 0

        Write-Verbose "Entering loop to check for CSE activity completion." 
        $done = $false
        
        While(!$done)
        {
            # Checkpoint to allow for recovery in case fairshare unloads runbook from worker.
            Checkpoint-Workflow

            # Re-authenticate to Azure in case runbook has been restarted by fairshare.
            Write-Verbose "Authenticating to Azure..."
            Add-AzureAccount -Credential $AzureOrgIdCredential | Write-Verbose
            Select-AzureSubscription -SubscriptionName $AzureSubscriptionName | Write-Verbose
            Set-AzureSubscription -SubscriptionName $AzureSubscriptionName -CurrentStorageAccountName $StorageAccountName | Write-Verbose

            $currentAttempt = $currentAttempt + 1

            $done = InlineScript{

                # Get the current timestamp of the cseStatus
                $status = Get-AzureVM -ServiceName $Using:ServiceName -Name $Using:VMName
                Write-Verbose "VM Status Object: $status"
                try
                {
                    $cseStatus = $status.ResourceExtensionStatusList | Where{$_.HandlerName -eq "Microsoft.Compute.CustomScriptExtension"}
                    $cseTimeStamp = $cseStatus.ExtensionSettingStatus.TimestampUtc.ToString()
                    $cseStdOut = $cseStatus.ExtensionSettingStatus.SubStatusList | Where{$_.Name -eq "StdOut"}
                    $cseStdErr = $cseStatus.ExtensionSettingStatus.SubStatusList | Where{$_.Name -eq "StdErr"}
                }
                catch
                {
                    Write-Verbose "Error getting previous Custom Script extension data, indicates CSE not currently enabled on this VM."
                    $cseTimeStamp = "empty"
                }                    
                Write-Verbose "TimeStamp: $cseTimeStamp"
                    
                # Evaluate timestamp of Resource Extension status to determine if job has completed.
                If($cseTimestamp -ne $Using:csePreviousTimeStamp)
                {
                    # Timestamp of Resource Extension has changed, indicating Update-AzureVM activity has completed
                    # Checking for errors in StdErr stream
                    Write-Verbose "CSE activity completed, checking output streams"
                    If($cseStdErr.FormattedMessage.Message -eq "")
                    {
                        # No errors returned. Outputting StdOut stream
                        Write-Verbose "No errors, outputting StdOut"
                        Write-Output $cseStdOut.FormattedMessage.Message
                    }
                    Else
                    {
                        # Errors returned, outputting to runbook.
                        Write-Verbose "Errors found, outputting StdErr and StdOut"
                        Write-Error "Custom Script Extension returned errors:" -ErrorAction Continue
                        Write-Error $cseStdErr.FormattedMessage.Message -ErrorAction Continue
                        
                        If($cseStdOut.FormattedMessage.Message)
                        {
                            Write-Output $cseStdOut.FormattedMessage.Message
                        }
                        Else
                        {
                            Write-Output $true
                        }
                    }
                        
                    # exit while loop
                    Write-Verbose "Exiting CSE Status check."
                }
                Else
                {
                    if($Using:currentAttempt -ne $Using:maxAttempts)
                    {
                        # CSE job not yet complete, sleep then re-evaluate
                        Write-Verbose "Sleeping before next CSE status evaluation."
                        Start-Sleep -Seconds $Using:PollingIntervalInSeconds
                        Write-Output $false
                    }
                    else
                    {
                        Write-Verbose "Timeout reached, existing CSE Status check."
                        Write-Error "Timeout reached, existing CSE Status check." -ErrorAction Continue
                        Write-Output $true
                    }
                }
            }
        }

        if($done -ne $true) {
            # Script had output, send it to calling runbook
            Write-Output $done
        }
        else {
            # Script did not have output
            Write-Verbose "No output produced by script"
        }
    }
    else
    {
        Write-Verbose "Push-AzureVMCommand completed successfully, however script may still be running on the target Virtual Machine."
        Write-Output "Success"
    }

    Write-Verbose "Runbook complete."
}