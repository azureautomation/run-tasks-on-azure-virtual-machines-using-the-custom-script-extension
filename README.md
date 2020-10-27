Run tasks on Azure Virtual Machines using the Custom Script Extension
=====================================================================

            

This Azure Automation runbook can be used to push a script or scriptblock to an Azure VM using the Custom Script extension component of the Azure VM Agent. This allows scripts to be run on Azure VM's without the need for the
 PowerShell Endpoint being enabled and WinRM configured.


This Runbook takes a PowerShell scriptblock supplied at runtime or an existing script and runs it on a defined Azure VM, optionally returning the output of the script or scriptblock.


The example below demonstrates usage of this runbook.


 

 

        
    
TechNet gallery is retiring! This script was migrated from TechNet script center to GitHub by Microsoft Azure Automation product group. All the Script Center fields like Rating, RatingCount and DownloadCount have been carried over to Github as-is for the migrated scripts only. Note : The Script Center fields will not be applicable for the new repositories created in Github & hence those fields will not show up for new Github repositories.
