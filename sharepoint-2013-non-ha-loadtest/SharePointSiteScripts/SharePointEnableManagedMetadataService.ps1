#Based on scripts at: 
# https://shannonbray.wordpress.com/2010/06/27/creating-a-sharepoint-web-application-with-powershell/
# and https://manojssharepointblog.wordpress.com/2013/06/27/creating-managed-metadata-service-application-using-powershell/
param(
	[Parameter(Mandatory=$true)]
	[String]$baseURL,
	[Parameter(Mandatory=$true)]
	[String]$dbServer,
	[Parameter(Mandatory=$true)]
	[String]$siteCollectionOwnerUserName,
	[String]$siteName = "ContentHub",
	[String]$appPoolName = "ContentHubPool",
	[String]$dbName = "ContentHub_Content",
	[String]$authenticationMethod = "NTLM",
	[String]$ManagedMetaDataAppPool = "ManagedMetaDataAppPool",
	[String]$ServiceDB = "MetadataDB",
	[String]$ManagedMetadataName = "Managed Metadata Service",
	[Int]$port = 2283,
	[Bool]$allowAnonymous = $false,
	[Bool]$ssl = $false
)

Add-PSSnapin Microsoft.SharePoint.PowerShell
Import-Module LogToFile

# Enable Distributed Cache Service
LogToFile -Message "Enabling the distributed cache service"
Add-SPDistributedCacheServiceInstance
LogToFile -Message "Done enabling the distributed cache service"

$Domain = (Get-CimInstance -ClassName Win32_ComputerSystem).Domain
$siteCollectionsOwnerAlias = "$($Domain)\$($siteCollectionOwnerUserName)"

# Create the Content Hub web application
LogToFile -Message "Creating web application for the managed metadata content hub"
$url = "$($baseURL):$($port)"
$managedAccount = Get-SPManagedAccount | Select-Object -First 1
$webApp = Get-SPWebApplication -Identity $url -ErrorAction SilentlyContinue
if(-not($webApp))
{
	New-SPWebApplication -Name $siteName -URL $url -ApplicationPool $appPoolName -ApplicationPoolAccount $managedAccount -DatabaseName $dbName `
	-DatabaseServer $dbServer -AllowAnonymousAccess:$allowAnonymous -AuthenticationMethod $authenticationMethod -SecureSocketsLayer:$ssl
}
LogToFile -Message "Done creating web application"

# Create the Content Hub site collection
LogToFile -Message "Creating the site collection for the managed metadata content hub"
$siteTemplate = Get-SPWebTemplate | Where-Object {$_.Title -eq "Developer Site"}
$spSite = Get-SPSite -Identity $url -ErrorAction SilentlyContinue
if(-not($spSite))
{
	New-SPSite -Url $url -OwnerAlias $siteCollectionsOwnerAlias -Template $siteTemplate
}
LogToFile -Message "Done creating the site collection"

# Enable content type syndication feature on the Content Hub site
LogToFile -Message "Enabling content syndication feature on the content hub site"
$spFeature = Get-SPFeature | Where-Object {$_.DisplayName -eq "ContentTypeHub"}
$spFeatureId = $spFeature[0].Id
Enable-SpFeature -Identity $spFeatureId -Url $url
LogToFile -Message "Done enabling the content syndication feature"

# Create the managed metadata service application pool
LogToFile -Message "Creating the application pool for the managed metadata service"
$appPool = Get-SPServiceApplicationPool -Identity $ManagedMetaDataAppPool -ErrorAction SilentlyContinue
if(-not($appPool))
{
	New-SPServiceApplicationPool -Name $ManagedMetaDataAppPool -Account $managedAccount
}
LogToFile -Message "Done creating the application pool"

# Start the managed metadata service
LogToFile -Message "Starting the managed metadata service"
$MetadataServiceInstance = Get-SPServiceInstance| Where-Object { $_.TypeName -eq "Managed Metadata Web Service" }
if (-not($MetadataServiceInstance))
{ 
	LogToFile -Message "ERROR: Did not find an instance of the managed metadata service"
	throw [System.Exception] "Did not find an instance of the managed metadata service" 
}
if ($MetadataServiceInstance.Status -eq "Disabled")
{
	Start-SPServiceInstance -Identity $MetadataServiceInstance
	if (-not($?)) 
	{ 
		LogToFile -Message "ERROR:Managed metadata service failed to start"
		throw [System.Exception] "Managed metadata service failed to start" 
	}
}
$retryCount = 0
while (-not($MetadataServiceInstance.Status -eq "Online"))
{
	if($retryCount -ge 60)
	{
		LogToFile -Message "ERROR:Starting managed matadata service has timed out"
		throw [System.Exception] "Starting managed metadata service has timed out" 
	}
	$MetadataServiceInstance = Get-SPServiceInstance| Where-Object { $_.TypeName -eq "Managed Metadata Web Service" }
	Start-Sleep -Seconds 5
	$retryCount++
}
LogToFile -Message "Managed metadata service has started"

# Create the managed metadata service application
LogToFile -Message "Creating the managed metadata service application"
$metadataServiceApp = Get-SPMetadataServiceApplication -Identity $ManagedMetadataName
if(-not($metadataServiceApp))
{
	New-SPMetadataServiceApplication -Name $ManagedMetadataName -ApplicationPool $ManagedMetaDataAppPool -DatabaseName $ServiceDB
	# Add the content hub to the metadata service application
	Set-SPMetadataServiceApplication -Identity $ManagedMetadataName -HubURI $url
	
	# Create the managed metadata service application proxy
	$metadataServiceAppProxy = New-SPMetadataServiceApplicationProxy -Name $ManagedMetadataName -ServiceApplication $ManagedMetadataName -DefaultProxyGroup
	$metadataServiceAppProxy.Properties[“IsDefaultSiteCollectionTaxonomy”] = $true
	$metadataServiceAppProxy.Properties[“IsNPContentTypeSyndicationEnabled”] = $false
	$metadataServiceAppProxy.Properties[“IsContentTypePushdownEnabled”] = $true
	$metadataServiceAppProxy.Update()
}
LogToFile -Message "Done creating the service application"
