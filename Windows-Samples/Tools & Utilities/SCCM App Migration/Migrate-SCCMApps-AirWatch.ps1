<# Migrate SCCMApps-AirWatch Powershell Script Help

  .SYNOPSIS
    This Powershell script allows you to automatically migrate SCCM applications over to AirWatch for management from the AirWatch console.
    MUST RUN AS ADMIN
    MUST UPDATE SCCM SITECODE
        
  .DESCRIPTION
    When run, this script will prompt you to select an application for migration. It then parses through the deployment details of the 
    application and pushes the application package to AirWatch. The script then maps all the deployment commands and settings over to the 
    AirWatch application record. MSIs are ported over as-is. Script deployments are ported over as ZIP folders with the correct execution 
    commands to unpack and apply them.      

  .EXAMPLE

    .\Migrate-SCCMApps-AirWatch.ps1 `
        -SCCMSiteCode "PAL:" `
        -AWServer "https://mondecorp.ssdevrd.com" `
        -userName "tkent" `
        -password "SecurePassword" `
        -tenantAPIKey "iVvHQnSXpX5elicaZPaIlQ8hCe5C/kw21K3glhZ+g/g=" `
        -groupID "652" `
        -Verbose

  .PARAMETER SCCMSiteCode
    The Site Code of the SCCM Server that the script can set the location to.

  .PARAMETER AWServer
    Server URL for the AirWatch API Server
  
  .PARAMETER userName
    An AirWatch account in the tenant is being queried.  This user must have the API role at a minimum.

  .PARAMETER password
    The password that is used by the user specified in the username parameter

  .PARAMETER tenantAPIKey
    This is the REST API key that is generated in the AirWatch Console.  You locate this key at All Settings -> Advanced -> API -> REST,
    and you will find the key in the API Key field.  If it is not there you may need override the settings and Enable API Access

  .PARAMETER groupID
    The groupID is the ID of the Organization Group where the apps will be migrated. The API key and admin credentials need to be authenticated
    at this Organization Group. The shorcut to getting this value is to navigate to https://<YOUR HOST>/AirWatch/#/AirWatch/OrganizationGroup/Details.
    The ID you are redirected to appears in the URL (7 in the following example). https://<YOUR HOST>/AirWatch/#/AirWatch/OrganizationGroup/Details/Index/7

#>

[CmdletBinding()]
    Param(
        [Parameter(Mandatory=$True)]
        [string]$SCCMSiteCode,
        
        [Parameter(Mandatory=$True)]
        [string]$AWServer,

        [Parameter(Mandatory=$True)]
        [string]$userName,

        [Parameter(Mandatory=$True)]
        [string]$password,

        [Parameter(Mandatory=$True)]
        [string]$tenantAPIKey,

        [Parameter(Mandatory=$True)]
        [string]$groupID
)

Write-Verbose "-- Command Line Parameters --"
Write-Verbose ("Site Code: " + $SCCMSiteCode)
Write-Verbose ("Site Code: " + $AWServer)
Write-Verbose ("UserName: " + $userName)
Write-Verbose ("Password: " + $password)
Write-Verbose ("Tenant API Key: " + $tenantAPIKey)
Write-Verbose ("Endpoint URL: " + $groupID)
Write-Verbose "-----------------------------"
Write-Verbose ""

Import-Module "$($ENV:SMS_ADMIN_UI_PATH)\..\ConfigurationManager.psd1" # Import the ConfigurationManager.psd1 module 
Set-Location $SCCMSiteCode # Set the current location to be the site code.

##Progress bar
Write-Progress -Activity "Application Export" -Status "Starting Script" -PercentComplete 10

##Get applicaion list via WMI
##$Applications = Get-WMIObject -ComputerName $SCCMServer -Namespace Root\SMS\Site_$SCCMSiteCode -Class "SMS_Application" | Select -unique LocalizedDisplayName | sort LocalizedDisplayName
$Applications = Get-CMApplication | Select LocalizedDisplayName | sort LocalizedDisplayName

##Application Import Selection Form
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Start Drawing Form. The form has some issues depending on the screen resolution. #Needs to be updated
$form1 = New-Object System.Windows.Forms.Form
$form1.Text = "Application Import"
$form1.Size = New-Object System.Drawing.Size(425,380)
$form1.StartPosition = "CenterScreen"

$OKButton1 = New-Object System.Windows.Forms.Button
$OKButton1.Location = New-Object System.Drawing.Point(300,325)
$OKButton1.Size = New-Object System.Drawing.Size(75,23)
$OKButton1.Text = "OK"
$OKButton1.DialogResult = [System.Windows.Forms.DialogResult]::OK
$OKButton1.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Right
$form1.AcceptButton = $OKButton1
$form1.Controls.Add($OKButton1)

$CancelButton1 = New-Object System.Windows.Forms.Button
$CancelButton1.Location = New-Object System.Drawing.Point(225,325)
$CancelButton1.Size = New-Object System.Drawing.Size(75,23)
$CancelButton1.Text = "Cancel"
$CancelButton1.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
$CancelButton1.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Right
$form1.CancelButton = $CancelButton1
$form1.Controls.Add($CancelButton1)

$label1 = New-Object System.Windows.Forms.Label
$label1.Location = New-Object System.Drawing.Point(10,5)
$label1.Size = New-Object System.Drawing.Size(280,20)
$label1.Text = "Select an application to import"
$form1.Controls.Add($label1)

$listBox1 = New-Object System.Windows.Forms.Listbox
$listBox1.Location = New-Object System.Drawing.Size(10,30)
$listBox1.Width = 400
$listBox1.Height = 296
$listBox1.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Right

##Add items to form
foreach($Application in $Applications)
{
    [void] $ListBox1.Items.Add($Application.LocalizedDisplayName)
}

#Display form to Admin
$form1.Controls.Add($listBox1)
$form1.Topmost = $True
$result1 = $form1.ShowDialog()

# If a valid input is selected then set Application else quit
if ($result1 -eq [System.Windows.Forms.DialogResult]::OK)
{
    $SelectedApplication = $listBox1.SelectedItems
    $SelectedApplication = $SelectedApplication[0]
}
else
{
    exit
}

##Progress bar
Write-Progress -Activity "Application Export" -Status "Searching for applications" -PercentComplete 30

#Parse the Deployment details of the Selected application and deserialize.
$selectedAppObject = Get-CMApplication -Name $SelectedApplication
[xml]$SDMPackageXML = $selectedAppObject.SDMPackageXML

##Progress bar
Write-Progress -Activity "Application Export" -Status "Finalizing" -PercentComplete 40

<#
  This implementation uses Basic authentication.  See "Client side" at https://en.wikipedia.org/wiki/Basic_access_authentication for a description
  of this implementation.
#>
Function Get-BasicUserForAuth {

	Param([string]$func_username)

	$userNameWithPassword = $func_username
	$encoding = [System.Text.Encoding]::ASCII.GetBytes($userNameWithPassword)
	$encodedString = [Convert]::ToBase64String($encoding)

	Return "Basic " + $encodedString
}

<#
  This method builds the headers for the REST API calls being made to the AirWatch Server.
#>
Function Build-Headers {

    Param([string]$authoriztionString, [string]$tenantCode, [string]$acceptType, [string]$contentType)

    $authString = $authoriztionString
    $tcode = $tenantCode
    $accept = $acceptType
    $content = $contentType

    Write-Verbose("---------- Headers ----------")
    Write-Verbose("Authorization: " + $authString)
    Write-Verbose("aw-tenant-code:" + $tcode)
    Write-Verbose("Accept: " + $accept)
    Write-Verbose("Content-Type: " + $content)
    Write-Verbose("------------------------------")
    Write-Verbose("")
    $header = @{"Authorization" = $authString; "aw-tenant-code" = $tcode; "Accept" = $useJSON; "Content-Type" = $useJSON}
     
    Return $header
}

<#
  This method extracts specific properties from the SCCM deployment details and stores them in an AirWatch Properties table.
  Different deployment modes require different properties to be stored.
#>
Function Extract-PackageProperties {

    [hashtable]$AirWatchProperties = @{}

    # Extract top level app properties
    $ApplicationName = $SDMPackageXML.AppMgmtDigest.Application.Title.InnerText
    $AirWatchProperties.Add("ApplicationName", $ApplicationName)
    $AirWatchProperties.Add("Description", $SDMPackageXML.AppMgmtDigest.Application.Description.InnerText)
    $AirWatchProperties.Add("Developer", $SDMPackageXML.AppMgmtDigest.Application.Publisher.InnerText)
    $AirWatchProperties.Add("ActualFileVersion", $SDMPackageXML.AppMgmtDigest.Application.SoftwareVersion.InnerText)

    # Get the first deployment method of multiple.
    $currentDeployment = $SDMPackageXML.AppMgmtDigest.DeploymentType | Select-Object -First 1

    # Map Install actions section to the corresponding AW properties
    $AirWatchProperties.Add("InstallCommand", ($currentDeployment.Installer.InstallAction.Args.Arg | ? {$_.Name -eq "InstallCommandLine"}).InnerText)
    $AirWatchProperties.Add("InstallerRebootExitCode", ($currentDeployment.Installer.InstallAction.Args.Arg | ? {$_.Name -eq "RebootExitCodes"}).InnerText)
    $AirWatchProperties.Add("InstallerSuccessExitCode", ($currentDeployment.Installer.InstallAction.Args.Arg | ? {$_.Name -eq "SuccessExitCodes"}).InnerText)
    $AirWatchProperties.Add("DeviceRestart", ($currentDeployment.Installer.InstallAction.Args.Arg | ? {$_.Name -eq "RequiresReboot"}).InnerText)
    $AirWatchProperties.Add("InstallTimeoutInMinutes", ($currentDeployment.Installer.InstallAction.Args.Arg | ? {$_.Name -eq "ExecuteTime"}).InnerText)

    # Only set Uninstall command if present
    if(($currentDeployment.Installer.UninstallAction.Args.Arg | ? {$_.Name -eq "InstallCommandLine"}).InnerText -eq $null) 
    {
        $AirWatchProperties.Add("UninstallCommandLine","An Uninstall Command is not setup in SCCM. Please update this field")
    } 
    else 
    {
        $AirWatchProperties.Add("UninstallCommandLine", ($currentDeployment.Installer.UninstallAction.Args.Arg | ? {$_.Name -eq "InstallCommandLine"}).InnerText)
    }


    #Set Default Install Context and modify if the Package context is System
    $AirWatchProperties.Add("InstallContext", "User")
        If(($SDMPackageXML.AppMgmtDigest.DeploymentType.Installer.InstallAction.Args.Arg | ? {$_.Name -eq "ExecutionContext"}).InnerText -eq "System")
    {
        $AirWatchProperties.Set_Item("InstallContext", "Device")
    }
    
    # Switch the file generation based on Deployment Technology. Script deployment files are zipped up into a single file.
    switch ($currentDeployment.Technology)
    {
        "MSI"    
                {
                    $source = $currentDeployment.Installer.Contents.Content.Location
                    $file = ($currentDeployment.Installer.Contents.Content.File | ? {$_.Name -like "*.msi"}).Name
                    $uploadFilePath = $source + $file
                    $AirWatchProperties.Add("FilePath", $uploadFilePath)
                }
        "Script" 
                {
                    #Zip Script deployments into a file for upload
                    $source = $currentDeployment.Installer.Contents.Content.Location
                    $parentFolder = ($source | Split-Path -Parent)
                    $folderName = ($source | Split-Path -Leaf)
                    $uploadFilePath = $parentFolder + "\$folderName.zip"
                    If(Test-path $uploadFilePath) {Remove-item $uploadFilePath}
                    Add-Type -assembly "system.io.compression.filesystem"
                    [io.compression.zipfile]::CreateFromDirectory($source, $uploadFilePath)
                    $AirWatchProperties.Add("FilePath", $uploadFilePath)
                }
    }

    # Get the application identifier from the Enhanced Detection Method

    if(($currentDeployment.Installer.DetectAction.Args.Arg | ? {$_.Name -eq "MethodBody"}).InnerText -eq $null)
    {
        $AirWatchProperties.Add("InstallApplicationIdentifier", "No Product Code Found")        
    }
    else 
    {
        [xml] $enhancedDetectionMethodXML = ($currentDeployment.Installer.DetectAction.Args.Arg | ? {$_.Name -eq "MethodBody"}).InnerText
        $InstallApplicationIdentifier = $enhancedDetectionMethodXML.EnhancedDetectionMethod.Settings.MSI.ProductCode
        $AirWatchProperties.Add("InstallApplicationIdentifier", $InstallApplicationIdentifier)
    }

    Write-Verbose("---------- AW Properties ----------")
    Write-Host $AirWatchProperties | Out-String 
    Write-Verbose("------------------------------")
    Write-Verbose("")

    return $AirWatchProperties
}

<#
  This method maps all the AirWatch Properties extracked and stored in a table to the corresponding JSON value in the AirWatch
  API body.
#>
Function Map-AppDetailsJSON {

    Param([hashtable] $awProperties)

    # Map all table values to the AirWatch JSON format
    $applicationProperties = @{
        ApplicationName = $awProperties.ApplicationName
	    AutoUpdateVersion = 'true'
	    BlobId = $awProperties.BlobID
	    DeploymentOptions = @{
		    WhenToInstall = @{
			    DiskSpaceRequiredInKb = 1
			    DevicePowerRequired= 2
			    RamRequiredInMb= 3
		    }
		    HowToInstall= @{
			    AdminPrivileges = "true"
			    DeviceRestart = "DoNotRestart"
			    InstallCommand = $awProperties.InstallCommand
			    InstallContext = $awProperties.InstallContext
			    InstallTimeoutInMinutes = $awProperties.InstallTimeoutInMinutes 
			    InstallerRebootExitCode = $awProperties.InstallerRebootExitCode 
			    InstallerSuccessExitCode = $awProperties.InstallerSuccessExitCode 
			    RetryCount = 3
			    RetryIntervalInMinutes = 5
		    }
		    WhenToCallInstallComplete = @{
			    UseAdditionalCriteria = "false"
			    IdentifyApplicationBy = "DefiningCriteria"
                CriteriaList = @(@{
                    CriteriaType = "AppExists"
				    LogicalCondition = "End"
                    AppCriteria = @{
                        ApplicationIdentifier = $awProperties.InstallApplicationIdentifier
                        VersionCondition = "Any"
                    }			    
                })
			    CustomScript = @{
				    ScriptType = "Unknown"
				    CommandToRunTheScript = "Text value"
				    CustomScriptFileBlodId = 3
				    SuccessExitCode = 1
			    }
		    }
	    }
	    FilesOptions = @{
		    ApplicationUnInstallProcess = @{
			    UseCustomScript = "true"
			    CustomScript =  @{
				    CustomScriptType = "Input"
				    UninstallCommand = $awProperties.UninstallCommandLine
			    }
		    }
	    }
	    Description = $awProperties.Description
	    Developer = $awProperties.Developer
	    DeveloperEmail = ""
	    DeveloperPhone = ""
	    DeviceType = 12
	    EnableProvisioning = "false"
	    FileName = $awProperties.UploadFileName
	    IsDependencyFile = "false"
	    LocationGroupId = $awProperties.LocationGroupId
	    MsiDeploymentParamModel = @{
		    CommandLineArguments = $awProperties.InstallCommand
		    InstallTimeoutInMinutes = $awProperties.InstallTimeoutInMinutes
		    RetryCount = 3
		    RetryIntervalInMinutes = 5
	    }
	    PushMode = 0
	    SupportEmail = ""
	    SupportPhone = ""
	    SupportedModels = @{
		    Model = @(@{
			    ApplicationId = 704
			    ModelId = 50
		    })
	    }
	    SupportedProcessorArchitecture = "x86"
    }

    $json = $applicationProperties | ConvertTo-Json -Depth 10
    Write-Verbose "------- JSON to Post---------"
    Write-Verbose $json
    Write-Verbose "-----------------------------"
    Write-Verbose ""
    
    Return $json
}

#MAIN

#Extract the hashtable returned from the function
$awProperties = (Extract-PackageProperties)[1]

#Generate Auth Headers from username and password
$concateUserInfo = $userName + ":" + $password
$deviceListURI = $baseURL + $bulkDeviceEndpoint
$restUserName = Get-BasicUserForAuth ($concateUserInfo)

# Define Content Types and Accept Types
$useJSON = "application/json"
$useOctetStream = "application/octet-stream"

#Build Headers
$headers = Build-Headers $restUserName $tenantAPIKey $useJSON $useOctetStream

# Extract Filename, configure Blob Upload API URL and invoke the API.
$uploadFileName = Split-Path $awProperties.FilePath -leaf
$awProperties.Add("LocationGroupId", $groupID)
$blobUploadEndpoint = "$AWServer/api/mam/blobs/uploadblob?filename=$uploadFileName&organizationgroupid=$groupID"
$networkFilePath = "Microsoft.Powershell.Core\FileSystem::" + $awProperties.FilePath
$blobUploadResponse = Invoke-RestMethod -Method Post -Uri $blobUploadEndpoint.ToString() -Headers $headers -InFile $networkFilePath

##Progress bar
Write-Progress -Activity "Application Export" -Status "Finalizing" -PercentComplete 70
Write-Verbose $blobUploadResponse

# Extract Blob ID and store in the properties table.
$blobID = $blobUploadResponse.Value
$awProperties.Add("BlobID", $blobID)
$awProperties.Add("UploadFileName", $uploadFileName)

##Progress bar
Write-Progress -Activity "Application Export" -Status "Exporting $SelectedApplication" -PercentComplete 80

# Call function to map all properties from SCCM to AirWatch JSON.
$appDetailsJSON = Map-AppDetailsJSON $awProperties
$saveAppDetailsEndpoint = "$AWServer/api/v1/mam/apps/internal/begininstall"
$webReturn = Invoke-RestMethod -Method Post -Uri $saveAppDetailsEndpoint.ToString() -Headers $headers -Body $appDetailsJSON

##Progress bar
Write-Progress -Activity "Application Export" -Status "Export of $SelectedApplication Completed" -PercentComplete 100
Write-Verbose $webReturn

#Fin
Write-Output "End"